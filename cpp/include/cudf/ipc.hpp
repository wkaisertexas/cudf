/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
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

#pragma once

#include <cudf/interop.hpp>           // column_metadata
#include <cudf/table/table_view.hpp>  // table_view
#include <memory>                     // std::shared_ptr
#include <string>
#include <utility>  // std::pair
#include <vector>

namespace arrow {
class Buffer;
}  // namespace arrow

namespace cudf {

/**
 * @addtogroup ipc
 * @{
 * @file
 */

namespace ipc {
class imported_ptr;
}  // namespace ipc

/**
 * @brief Represents meta data of a column imported from IPC memory handle.
 *
 * This RAII class holds the imported pointer from IPC handle and will close it upon
 * destruction, hence the life time of imported column is tied to this class.
 */
class imported_column {
 public:
  std::string name;

 private:
  struct impl;
  std::unique_ptr<impl> _pimpl;

 public:
  imported_column(imported_column const& that) = delete;
  imported_column(std::string n, ipc::imported_ptr&& d, ipc::imported_ptr&& m);
  imported_column(std::string n, ipc::imported_ptr&& d);
  imported_column(std::string n,
                  ipc::imported_ptr&& d,
                  ipc::imported_ptr&& m,
                  std::vector<std::shared_ptr<imported_column>>&& children);
  ~imported_column();
};

/**
 * @brief Exports a buffer that contains serialized IPC handles for each column.
 *
 * This function exports a buffer of serialized CUDA IPC memory handles, which can be
 * consumed by another process on the same device without making any copy of the data.
 *
 * @throw cudf::logic_error if any of the data types are unsupported
 *
 * @param input Input table to be exported for IPC
 * @param metadata Contains hierarchy of names of columns and children
 *
 * @return A shared pointer to an arrow buffer that contains the bytes of serialized CUDA
 *         IPC memory handles along with schema.
 */
std::shared_ptr<arrow::Buffer> export_ipc(table_view input,
                                          std::vector<column_metadata> const& metadata);

/**
 * @brief Imports a buffer that's generated by `export_ipc`.
 *
 * @note No device memory allocation is perform in this function, the life time of
 * returned table is tied to the `imported_colum` class.
 *
 * @return The restored table from IPC handle and a vector of `imported_column` that are
 * responsible for closing the memory handles.
 */
std::pair<table_view, std::vector<std::shared_ptr<imported_column>>> import_ipc(
  std::shared_ptr<arrow::Buffer> ipc_handles);

/** @} */  // end of group
}  // namespace cudf