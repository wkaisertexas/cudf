/*
 * Copyright (c) 2020-2024, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/interop.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/unary.hpp>
#include <cudf/dictionary/dictionary_column_view.hpp>
#include <cudf/interop.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/exec_policy.hpp>
#include <rmm/mr/device/per_device_resource.hpp>

#include <thrust/copy.h>
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>

#include <cudf/interop/nanoarrow/nanoarrow.h>
#include <cudf/interop/nanoarrow/nanoarrow.hpp>
#include <cudf/interop/nanoarrow/nanoarrow_device.h>

namespace cudf {
namespace detail {
namespace {
ArrowType id_to_arrow_type(cudf::type_id id)
{
  switch (id) {
    case cudf::type_id::BOOL8: return NANOARROW_TYPE_BOOL;
    case cudf::type_id::INT8: return NANOARROW_TYPE_INT8;
    case cudf::type_id::INT16: return NANOARROW_TYPE_INT16;
    case cudf::type_id::INT32: return NANOARROW_TYPE_INT32;
    case cudf::type_id::INT64: return NANOARROW_TYPE_INT64;
    case cudf::type_id::UINT8: return NANOARROW_TYPE_UINT8;
    case cudf::type_id::UINT16: return NANOARROW_TYPE_UINT16;
    case cudf::type_id::UINT32: return NANOARROW_TYPE_UINT32;
    case cudf::type_id::UINT64: return NANOARROW_TYPE_UINT64;
    case cudf::type_id::FLOAT32: return NANOARROW_TYPE_FLOAT;
    case cudf::type_id::FLOAT64: return NANOARROW_TYPE_DOUBLE;
    case cudf::type_id::TIMESTAMP_DAYS: return NANOARROW_TYPE_DATE32;
    default: CUDF_FAIL("Unsupported type_id conversion to arrow type");
  }
}

struct dispatch_to_arrow_type {
  template <typename T, CUDF_ENABLE_IF(not is_rep_layout_compatible<T>())>
  int operator()(column_view, cudf::type_id, column_metadata const&, struct ArrowSchema*)
  {
    CUDF_FAIL("Unsupported type for to_arrow_schema");
  }

  template <typename T, CUDF_ENABLE_IF(is_rep_layout_compatible<T>())>
  int operator()(column_view input_view,
                 cudf::type_id id,
                 column_metadata const&,
                 struct ArrowSchema* out)
  {
    switch (id) {
      case cudf::type_id::TIMESTAMP_SECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_TIMESTAMP, NANOARROW_TIME_UNIT_SECOND, nullptr);
      case cudf::type_id::TIMESTAMP_MILLISECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_TIMESTAMP, NANOARROW_TIME_UNIT_MILLI, nullptr);
      case cudf::type_id::TIMESTAMP_MICROSECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_TIMESTAMP, NANOARROW_TIME_UNIT_MICRO, nullptr);
      case cudf::type_id::TIMESTAMP_NANOSECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_TIMESTAMP, NANOARROW_TIME_UNIT_NANO, nullptr);
      case cudf::type_id::DURATION_SECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_DURATION, NANOARROW_TIME_UNIT_SECOND, nullptr);
      case cudf::type_id::DURATION_MILLISECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_DURATION, NANOARROW_TIME_UNIT_MILLI, nullptr);
      case cudf::type_id::DURATION_MICROSECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_DURATION, NANOARROW_TIME_UNIT_MICRO, nullptr);
      case cudf::type_id::DURATION_NANOSECONDS:
        return ArrowSchemaSetTypeDateTime(
          out, NANOARROW_TYPE_DURATION, NANOARROW_TIME_UNIT_NANO, nullptr);
      default: return ArrowSchemaSetType(out, id_to_arrow_type(id));
    }
  }
};

template <typename DeviceType>
int decimals_to_arrow(column_view input, struct ArrowSchema* out)
{
  return ArrowSchemaSetTypeDecimal(out,
                                   NANOARROW_TYPE_DECIMAL128,
                                   cudf::detail::max_precision<DeviceType>(),
                                   -input.type().scale());
}

template <>
int dispatch_to_arrow_type::operator()<numeric::decimal32>(column_view input,
                                                           cudf::type_id,
                                                           column_metadata const&,
                                                           struct ArrowSchema* out)
{
  using DeviceType = int32_t;
  return decimals_to_arrow<DeviceType>(input, out);
}

template <>
int dispatch_to_arrow_type::operator()<numeric::decimal64>(column_view input,
                                                           cudf::type_id,
                                                           column_metadata const&,
                                                           struct ArrowSchema* out)
{
  using DeviceType = int64_t;
  return decimals_to_arrow<DeviceType>(input, out);
}

template <>
int dispatch_to_arrow_type::operator()<numeric::decimal128>(column_view input,
                                                            cudf::type_id,
                                                            column_metadata const&,
                                                            struct ArrowSchema* out)
{
  using DeviceType = __int128_t;
  return decimals_to_arrow<DeviceType>(input, out);
}

template <>
int dispatch_to_arrow_type::operator()<bool>(column_view input,
                                             cudf::type_id,
                                             column_metadata const&,
                                             struct ArrowSchema* out)
{
  return ArrowSchemaSetType(out, NANOARROW_TYPE_BOOL);
}

template <>
int dispatch_to_arrow_type::operator()<cudf::string_view>(column_view input,
                                                          cudf::type_id,
                                                          column_metadata const&,
                                                          struct ArrowSchema* out)
{
  return ArrowSchemaSetType(out, NANOARROW_TYPE_STRING);
}

template <>
int dispatch_to_arrow_type::operator()<cudf::list_view>(column_view input,
                                                        cudf::type_id,
                                                        column_metadata const& metadata,
                                                        struct ArrowSchema* out);

template <>
int dispatch_to_arrow_type::operator()<cudf::dictionary32>(column_view input,
                                                           cudf::type_id,
                                                           column_metadata const& metadata,
                                                           struct ArrowSchema* out);

template <>
int dispatch_to_arrow_type::operator()<cudf::struct_view>(column_view input,
                                                          cudf::type_id,
                                                          column_metadata const& metadata,
                                                          struct ArrowSchema* out)
{
  CUDF_EXPECTS(metadata.children_meta.size() == static_cast<std::size_t>(input.num_children()),
               "Number of field names and number of children doesn't match\n");

  NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeStruct(out, input.num_children()));
  for (int i = 0; i < input.num_children(); ++i) {
    auto child = out->children[i];
    auto col   = input.child(i);
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetName(child, metadata.name.c_str()));
    child->flags = col.nullable() ? ARROW_FLAG_NULLABLE : 0;

    if (col.type().id() == cudf::type_id::EMPTY) {
      NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(child, NANOARROW_TYPE_NA));
      continue;
    }

    NANOARROW_RETURN_NOT_OK(cudf::type_dispatcher(col.type(),
                                                  detail::dispatch_to_arrow_type{},
                                                  col,
                                                  col.type().id(),
                                                  metadata.children_meta[i],
                                                  child));
  }

  return NANOARROW_OK;
}

template <>
int dispatch_to_arrow_type::operator()<cudf::list_view>(column_view input,
                                                        cudf::type_id,
                                                        column_metadata const& metadata,
                                                        struct ArrowSchema* out)
{
  NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(out, NANOARROW_TYPE_LIST));
  auto child = input.child(0);
  if (child.type().id() == cudf::type_id::EMPTY) {
    return ArrowSchemaSetType(out->children[0], NANOARROW_TYPE_NA);
  }
  out->flags = child.nullable() ? ARROW_FLAG_NULLABLE : 0;

  auto child_meta =
    metadata.children_meta.empty() ? column_metadata{"element"} : metadata.children_meta[0];
  return cudf::type_dispatcher(child.type(),
                               detail::dispatch_to_arrow_type{},
                               child,
                               child.type().id(),
                               child_meta,
                               out->children[0]);
}

template <>
int dispatch_to_arrow_type::operator()<cudf::dictionary32>(column_view input,
                                                           cudf::type_id,
                                                           column_metadata const& metadata,
                                                           struct ArrowSchema* out)
{
  cudf::dictionary_column_view dview{input};
  NANOARROW_RETURN_NOT_OK(ArrowSchemaAllocateDictionary(out));
  NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(out, id_to_arrow_type(dview.indices().type().id())));

  auto dict_keys = dview.keys();
  return cudf::type_dispatcher(
    dict_keys.type(),
    detail::dispatch_to_arrow_type{},
    dict_keys,
    dict_keys.type().id(),
    metadata.children_meta.empty() ? column_metadata{"keys"} : metadata.children_meta[0],
    out->dictionary);
}

template <typename T>
static void device_buffer_finalize(ArrowBufferAllocator* allocator, uint8_t*, int64_t)
{
  auto* unique_buffer = reinterpret_cast<std::unique_ptr<T>*>(allocator->private_data);
  delete unique_buffer;
}

template <typename T>
void set_buffer(std::unique_ptr<T>& device_buf, int64_t i, struct ArrowArray* out)
{
  ArrowBuffer* buf = ArrowArrayBuffer(out, i);
  buf->data        = reinterpret_cast<uint8_t*>(device_buf->data());
  // we make a new unique_ptr and move to it in case there was a custom deleter
  ArrowBufferSetAllocator(buf,
                          ArrowBufferDeallocator(&device_buffer_finalize<T>,
                                                 new std::unique_ptr<T>(std::move(device_buf))));
}

struct dispatch_to_arrow_device {
  template <typename T, CUDF_ENABLE_IF(not is_rep_layout_compatible<T>())>
  int operator()(cudf::column&,
                 cudf::type_id,
                 rmm::cuda_stream_view,
                 rmm::mr::device_memory_resource*,
                 struct ArrowArray*)
  {
    CUDF_FAIL("Unsupportd type for to_arrow_device");
  }

  template <typename T, CUDF_ENABLE_IF(is_rep_layout_compatible<T>())>
  int operator()(cudf::column& column,
                 cudf::type_id id,
                 rmm::cuda_stream_view stream,
                 rmm::mr::device_memory_resource* mr,
                 struct ArrowArray* out)
  {
    nanoarrow::UniqueArray tmp;

    ArrowType storage_type;
    switch (id) {
      case cudf::type_id::TIMESTAMP_SECONDS:
      case cudf::type_id::TIMESTAMP_MILLISECONDS:
      case cudf::type_id::TIMESTAMP_MICROSECONDS:
      case cudf::type_id::TIMESTAMP_NANOSECONDS: storage_type = NANOARROW_TYPE_TIMESTAMP; break;
      case cudf::type_id::DURATION_SECONDS:
      case cudf::type_id::DURATION_MILLISECONDS:
      case cudf::type_id::DURATION_MICROSECONDS:
      case cudf::type_id::DURATION_NANOSECONDS: storage_type = NANOARROW_TYPE_DURATION; break;
      default: storage_type = id_to_arrow_type(id);
    }

    NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromType(tmp.get(), storage_type));
    tmp->length     = column.size();
    tmp->null_count = column.null_count();

    auto contents = column.release();
    if (contents.null_mask) { set_buffer(contents.null_mask, 0, tmp.get()); }

    set_buffer(contents.data, 1, tmp.get());

    NANOARROW_RETURN_NOT_OK(
      ArrowArrayFinishBuilding(tmp.get(), NANOARROW_VALIDATION_LEVEL_NONE, nullptr));
    ArrowArrayMove(tmp.get(), out);
    return NANOARROW_OK;
  }
};

template <typename DeviceType>
int unsupported_decimals_to_arrow(cudf::column& input,
                                  int32_t precision,
                                  rmm::cuda_stream_view stream,
                                  rmm::mr::device_memory_resource* mr,
                                  struct ArrowArray* out)
{
  nanoarrow::UniqueArray tmp;
  NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromType(tmp.get(), NANOARROW_TYPE_DECIMAL128));

  constexpr size_type BIT_WIDTH_RATIO = sizeof(__int128_t) / sizeof(DeviceType);
  auto buf =
    std::make_unique<rmm::device_uvector<DeviceType>>(input.size() * BIT_WIDTH_RATIO, stream, mr);

  auto count = thrust::make_counting_iterator(0);

  thrust::for_each(rmm::exec_policy(stream, mr),
                   count,
                   count + input.size(),
                   [in  = input.view().begin<DeviceType>(),
                    out = buf->data(),
                    BIT_WIDTH_RATIO] __device__(auto in_idx) {
                     auto const out_idx = in_idx * BIT_WIDTH_RATIO;
                     // the lowest order bits are the value, the remainder
                     // simply matches the sign bit to satisfy the two's
                     // complement integer representation of negative numbers.
                     out[out_idx] = in[in_idx];
#pragma unroll BIT_WIDTH_RATIO - 1
                     for (auto i = 1; i < BIT_WIDTH_RATIO; ++i) {
                       out[out_idx + i] = in[in_idx] < 0 ? -1 : 0;
                     }
                   });

  tmp->length     = input.size();
  tmp->null_count = input.null_count();

  auto contents = input.release();
  if (contents.null_mask) { set_buffer(contents.null_mask, 0, tmp.get()); }
  set_buffer(buf, 1, tmp.get());

  NANOARROW_RETURN_NOT_OK(
    ArrowArrayFinishBuilding(tmp.get(), NANOARROW_VALIDATION_LEVEL_NONE, nullptr));
  ArrowArrayMove(tmp.get(), out);
  return NANOARROW_OK;
}

template <>
int dispatch_to_arrow_device::operator()<numeric::decimal32>(cudf::column& column,
                                                             cudf::type_id,
                                                             rmm::cuda_stream_view stream,
                                                             rmm::mr::device_memory_resource* mr,
                                                             struct ArrowArray* out)
{
  using DeviceType = int32_t;
  return unsupported_decimals_to_arrow<DeviceType>(
    column, cudf::detail::max_precision<DeviceType>(), stream, mr, out);
}

template <>
int dispatch_to_arrow_device::operator()<numeric::decimal64>(cudf::column& column,
                                                             cudf::type_id id,
                                                             rmm::cuda_stream_view stream,
                                                             rmm::mr::device_memory_resource* mr,
                                                             struct ArrowArray* out)
{
  using DeviceType = int64_t;
  return unsupported_decimals_to_arrow<DeviceType>(
    column, cudf::detail::max_precision<DeviceType>(), stream, mr, out);
}

template <>
int dispatch_to_arrow_device::operator()<numeric::decimal128>(cudf::column& column,
                                                              cudf::type_id id,
                                                              rmm::cuda_stream_view stream,
                                                              rmm::mr::device_memory_resource* mr,
                                                              struct ArrowArray* out)
{
  nanoarrow::UniqueArray tmp;
  NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromType(tmp.get(), NANOARROW_TYPE_DECIMAL128));
  tmp->length     = column.size();
  tmp->null_count = column.null_count();

  auto contents = column.release();
  if (contents.null_mask) { set_buffer(contents.null_mask, 0, tmp.get()); }

  set_buffer(contents.data, 1, tmp.get());

  NANOARROW_RETURN_NOT_OK(
    ArrowArrayFinishBuilding(tmp.get(), NANOARROW_VALIDATION_LEVEL_NONE, nullptr));
  ArrowArrayMove(tmp.get(), out);
  return NANOARROW_OK;
}

template <>
int dispatch_to_arrow_device::operator()<bool>(cudf::column& column,
                                               cudf::type_id id,
                                               rmm::cuda_stream_view stream,
                                               rmm::mr::device_memory_resource* mr,
                                               struct ArrowArray* out)
{
  nanoarrow::UniqueArray tmp;
  NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromType(tmp.get(), NANOARROW_TYPE_BOOL));
  tmp->length     = column.size();
  tmp->null_count = column.null_count();

  auto bitmask  = bools_to_mask(column.view(), stream, mr);
  auto contents = column.release();
  if (contents.null_mask) { set_buffer(contents.null_mask, 0, tmp.get()); }
  set_buffer(bitmask.first, 1, tmp.get());

  NANOARROW_RETURN_NOT_OK(
    ArrowArrayFinishBuilding(tmp.get(), NANOARROW_VALIDATION_LEVEL_NONE, nullptr));
  ArrowArrayMove(tmp.get(), out);
  return NANOARROW_OK;
}

template <>
int dispatch_to_arrow_device::operator()<cudf::string_view>(cudf::column& column,
                                                            cudf::type_id id,
                                                            rmm::cuda_stream_view stream,
                                                            rmm::mr::device_memory_resource* mr,
                                                            struct ArrowArray* out)
{
  CUDF_FAIL("Unsupported type for to_arrow_device");
}

template <>
int dispatch_to_arrow_device::operator()<cudf::list_view>(cudf::column& column,
                                                          cudf::type_id id,
                                                          rmm::cuda_stream_view stream,
                                                          rmm::mr::device_memory_resource* mr,
                                                          struct ArrowArray* out);

template <>
int dispatch_to_arrow_device::operator()<cudf::dictionary32>(cudf::column& column,
                                                             cudf::type_id id,
                                                             rmm::cuda_stream_view stream,
                                                             rmm::mr::device_memory_resource* mr,
                                                             struct ArrowArray* out);

template <>
int dispatch_to_arrow_device::operator()<cudf::struct_view>(cudf::column& column,
                                                            cudf::type_id id,
                                                            rmm::cuda_stream_view stream,
                                                            rmm::mr::device_memory_resource* mr,
                                                            struct ArrowArray* out)
{
  CUDF_FAIL("Unsupported type for to_arrow_device");
}

template <>
int dispatch_to_arrow_device::operator()<cudf::list_view>(cudf::column& column,
                                                          cudf::type_id id,
                                                          rmm::cuda_stream_view stream,
                                                          rmm::mr::device_memory_resource* mr,
                                                          struct ArrowArray* out)
{
  CUDF_FAIL("Unsupported type for to_arrow_device");
}

template <>
int dispatch_to_arrow_device::operator()<cudf::dictionary32>(cudf::column& column,
                                                             cudf::type_id id,
                                                             rmm::cuda_stream_view stream,
                                                             rmm::mr::device_memory_resource* mr,
                                                             struct ArrowArray* out)
{
  CUDF_FAIL("Unsupported type for to_arrow_device");
}

}  // namespace
}  // namespace detail

nanoarrow::UniqueSchema to_arrow_schema(cudf::table_view const& input,
                                        std::vector<column_metadata> const& metadata)
{
  CUDF_EXPECTS((metadata.size() == static_cast<std::size_t>(input.num_columns())),
               "columns' metadata should be equal to the number of columns in table");

  nanoarrow::UniqueSchema result;
  ArrowSchemaInit(result.get());
  if (ArrowSchemaSetTypeStruct(result.get(), input.num_columns()) != NANOARROW_OK) {
    CUDF_FAIL("failed to initialize ArrowSchema children");
  }

  // what i would give for a zip iterator....
  for (int i = 0; i < input.num_columns(); ++i) {
    auto child = result->children[i];
    auto col   = input.column(i);
    ArrowSchemaSetName(child, metadata[i].name.c_str());
    child->flags = col.nullable() ? ARROW_FLAG_NULLABLE : 0;

    if (col.type().id() == cudf::type_id::EMPTY) {
      ArrowSchemaSetType(child, NANOARROW_TYPE_NA);
      continue;
    }

    auto status = cudf::type_dispatcher(
      col.type(), detail::dispatch_to_arrow_type{}, col, col.type().id(), metadata[i], child);
    CUDF_EXPECTS(status == NANOARROW_OK, "type dispatcher failed to determine column type");
  }

  return result;
}

struct ArrowDeviceArray to_arrow_device(cudf::table& table,
                                        rmm::cuda_stream_view stream,
                                        rmm::mr::device_memory_resource* mr)
{
  nanoarrow::UniqueArray tmp;
  ArrowArrayInitFromType(tmp.get(), NANOARROW_TYPE_STRUCT);

  ArrowArrayAllocateChildren(tmp.get(), table.num_columns());
  tmp->length     = table.num_rows();
  tmp->null_count = 0;

  auto cols = table.release();
  for (size_t i = 0; i < cols.size(); ++i) {
    auto child = tmp->children[i];
    auto col   = cols[i].get();

    if (col->type().id() == cudf::type_id::EMPTY) {
      ArrowArrayInitFromType(child, NANOARROW_TYPE_NA);
      child->length     = col->size();
      child->null_count = col->size();
      continue;
    }

    auto status = cudf::type_dispatcher(
      col->type(), detail::dispatch_to_arrow_device{}, *col, col->type().id(), stream, mr, child);
    CUDF_EXPECTS(status == NANOARROW_OK, "type dispatcher failed to convert to ArrowArray");
  }

  auto event = std::make_unique<cudaEvent_t>();
  cudaEventCreate(event.get());

  auto status = cudaEventRecord(*event, stream);
  if (status != cudaSuccess) { CUDF_FAIL("could not create event to sync on"); }

  void* sync_event = event.release();

  ArrowBuffer* buf = ArrowArrayBuffer(tmp.get(), 0);
  buf->data        = nullptr;
  ArrowBufferSetAllocator(buf,
                          ArrowBufferDeallocator(
                            [](ArrowBufferAllocator* allocator, uint8_t*, int64_t) {
                              auto* unique_ev =
                                reinterpret_cast<cudaEvent_t*>(allocator->private_data);
                              cudaEventDestroy(*unique_ev);
                              delete unique_ev;
                            },
                            sync_event));

  struct ArrowDeviceArray result;
  result.device_id = rmm::get_current_cuda_device().value();
  // can/should we check whether the memory is managed/cuda_host memory?
  result.device_type = ARROW_DEVICE_CUDA;
  result.sync_event  = sync_event;
  ArrowArrayMove(tmp.get(), &result.array);
  return result;
}

}  // namespace cudf