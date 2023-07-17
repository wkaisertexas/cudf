# Copyright (c) 2023, NVIDIA CORPORATION.

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Tuple, Union

import numpy as np
from typing_extensions import TypeAlias

import cudf
import cudf._lib as libcudf
from cudf._lib.types import size_type_dtype
from cudf.api.types import (
    _is_scalar_or_zero_d_array,
    is_bool_dtype,
    is_integer,
    is_integer_dtype,
    is_scalar,
)
from cudf.core.column_accessor import ColumnAccessor
from cudf.core.copy_types import BooleanMask, GatherMap

if TYPE_CHECKING:
    from cudf.core.column import ColumnBase


class EmptyIndexer:
    """An indexer that will produce an empty result."""

    pass


@dataclass
class MapIndexer:
    """An indexer for a gather map."""

    key: GatherMap


@dataclass
class MaskIndexer:
    """An indexer for a boolean mask."""

    key: BooleanMask


@dataclass
class SliceIndexer:
    """An indexer for a slice."""

    key: slice


@dataclass
class ScalarIndexer:
    """An indexer for a scalar value."""

    key: GatherMap


IndexingSpec: TypeAlias = Union[
    EmptyIndexer, MapIndexer, MaskIndexer, ScalarIndexer, SliceIndexer
]


def destructure_iloc_key(
    key: Any, frame: Union[cudf.Series, cudf.DataFrame]
) -> tuple[Any, ...]:
    """
    Destructure a potentially tuple-typed key into row and column indexers.

    Tuple arguments to iloc indexing are treated specially. They are
    picked apart into indexers for the row and column. If the number
    of entries is less than the number of modes of the frame, missing
    entries are slice-expanded.

    If the user-provided key is not a tuple, it is treated as if it
    were a singleton tuple, and then slice-expanded.

    Once this destructuring has occurred, any entries that are
    callables are then called with the indexed frame. This should
    return a valid indexing object for the rows (respectively
    columns), namely one of:

    - A boolean mask of the same length as the frame in the given
      dimension
    - A scalar integer that indexes the frame
    - An array-like of integers that index the frame
    - A slice that indexes the frame

    Integer and slice-based indexing follows usual Python conventions.

    Parameters
    ----------
    key
        The key to destructure
    frame
        DataFrame or Series to provide context

    Returns
    -------
    tuple
        Indexers with length equal to the dimension of the frame

    Raises
    ------
    IndexError
        If there are too many indexers, or any individual indexer is a tuple.
    """
    n = len(frame.shape)
    if isinstance(key, tuple):
        # Key potentially indexes rows and columns, slice-expand to
        # shape of frame
        indexers = key + (slice(None),) * (n - len(key))
        if len(indexers) > n:
            raise IndexError(
                f"Too many indexers: got {len(indexers)} expected {n}"
            )
    else:
        # Key indexes rows, slice-expand to shape of frame
        indexers = (key, *(slice(None),) * (n - 1))
    indexers = tuple(k(frame) if callable(k) else k for k in indexers)
    if any(isinstance(k, tuple) for k in indexers):
        raise IndexError(
            "Too many indexers: can't have nested tuples in iloc indexing"
        )
    return indexers


def destructure_dataframe_iloc_indexer(
    key: Any, frame: cudf.DataFrame
) -> Tuple[Any, Tuple[bool, ColumnAccessor]]:
    """Destructure an index key for DataFrame iloc getitem.

    Parameters
    ----------
    key
        Key to destructure
    frame
        DataFrame to provide context context

    Returns
    -------
    tuple
        2-tuple of a key for the rows and tuple of
        (column_index_is_scalar, column_names) for the columns

    Raises
    ------
    TypeError
        If the column indexer is invalid
    IndexError
        If the provided key does not destructure correctly
    NotImplementedError
        If the requested column indexer repeats columns
    """
    rows, cols = destructure_iloc_key(key, frame)
    if cols is Ellipsis:
        cols = slice(None)
    scalar = is_integer(cols)
    try:
        ca = frame._data.select_by_index(cols)
    except TypeError:
        raise TypeError(
            "Column indices must be integers, slices, "
            "or list-like of integers"
        )
    if scalar:
        assert (
            len(ca) == 1
        ), "Scalar column indexer should not produce more than one column"

    return rows, (scalar, ca)


def destructure_series_iloc_indexer(key: Any, frame: cudf.Series) -> Any:
    """Destructure an index key for Series iloc getitem.

    Parameters
    ----------
    key
        Key to destructure
    frame
        Series for unpacking context

    Returns
    -------
    Single key that will index the rows
    """
    (rows,) = destructure_iloc_key(key, frame)
    return rows


def parse_row_iloc_indexer(key: Any, n: int) -> IndexingSpec:
    """
    Normalize and produce structured information about a row indexer.

    Given a row indexer that has already been destructured by
    :func:`destructure_iloc_key`, inspect further and produce structured
    information for indexing operations to act upon.

    Parameters
    ----------
    key
        Suitably destructured key for row indexing
    n
        Length of frame to index

    Returns
    -------
    IndexingSpec
        Structured data for indexing. A tag + parsed data.

    Raises
    ------
    IndexError
        If a valid type of indexer is provided, but it is out of
        bounds
    TypeError
        If the indexing key is otherwise invalid.
    """
    if key is Ellipsis:
        return SliceIndexer(slice(None))
    elif isinstance(key, slice):
        return SliceIndexer(key)
    elif _is_scalar_or_zero_d_array(key):
        return ScalarIndexer(GatherMap(key, n, nullify=False))
    else:
        key = cudf.core.column.as_column(key)
        if isinstance(key, cudf.core.column.CategoricalColumn):
            key = key.as_numerical_column(key.codes.dtype)
        if is_bool_dtype(key.dtype):
            return MaskIndexer(BooleanMask(key, n))
        elif len(key) == 0:
            return EmptyIndexer()
        elif is_integer_dtype(key.dtype):
            return MapIndexer(GatherMap(key, n, nullify=False))
        else:
            raise TypeError(
                "Cannot index by location "
                f"with non-integer key of type {type(key)}"
            )


def destructure_loc_key(
    key: Any, frame: cudf.Series | cudf.DataFrame
) -> tuple[Any, ...]:
    """
    Destructure a potentially tuple-typed key into row and column indexers

    Tuple arguments to loc indexing are treated specially. They are
    picked apart into indexers for the row and column. If the number
    of entries is less than the number of modes of the frame, missing
    entries are slice-expanded.

    If the user-provided key is not a tuple, it is treated as if it
    were a singleton tuple, and then slice-expanded.

    Once this destructuring has occurred, any entries that are
    callables are then called with the indexed frame. This should
    return a valid indexing object for the rows (respectively
    columns), namely one of:

    - A boolean mask of the same length as the frame in the given
      dimension
    - A scalar label looked up in the index
    - A scalar integer that indexes the frame
    - An array-like of labels looked up in the index
    - A slice of the index
    - For multiindices, a tuple of per level indexers

    Slice-based indexing is on the closed interval [start, end], rather
    than the semi-open interval [start, end)

    Parameters
    ----------
    key
        The key to destructure
    frame
        DataFrame or Series to provide context

    Returns
    -------
    tuple of indexers with length equal to the dimension of the frame

    Raises
    ------
    IndexError
        If there are too many indexers.
    """
    n = len(frame.shape)
    if (
        isinstance(frame.index, cudf.MultiIndex)
        and n == 2
        and isinstance(key, tuple)
        and all(map(is_scalar, key))
    ):
        # This is "best-effort" and ambiguous
        if len(key) == 2:
            if key[1] in frame.index._columns[1]:
                # key just indexes the rows
                key = (key,)
            elif key[1] in frame._data:
                # key indexes rows and columns
                key = key
            else:
                # key indexes rows and we will raise a keyerror
                key = (key,)
        else:
            # key just indexes rows
            key = (key,)
    if isinstance(key, tuple):
        # Key potentially indexes rows and columns, slice-expand to
        # shape of frame
        indexers = key + (slice(None),) * (n - len(key))
        if len(indexers) > n:
            raise IndexError(
                f"Too many indexers: got {len(indexers)} expected {n}"
            )
    else:
        # Key indexes rows, slice-expand to shape of frame
        indexers = (key, *(slice(None),) * (n - 1))
    return tuple(k(frame) if callable(k) else k for k in indexers)


def destructure_dataframe_loc_indexer(
    key: Any, frame: cudf.DataFrame
) -> Tuple[Any, Tuple[bool, ColumnAccessor]]:
    """Destructure an index key for DataFrame loc getitem.

    Parameters
    ----------
    key
        Key to destructure
    frame
        DataFrame to provide context context

    Returns
    -------
    tuple
        2-tuple of a key for the rows and tuple of
        (column_index_is_scalar, column_names) for the columns

    Raises
    ------
    TypeError
        If the column indexer is invalid
    IndexError
        If the provided key does not destructure correctly
    NotImplementedError
        If the requested column indexer repeats columns
    """
    rows, cols = destructure_loc_key(key, frame)
    if cols is Ellipsis:
        cols = slice(None)
    try:
        scalar = cols in frame._data
    except TypeError:
        scalar = False
    try:
        ca = frame._data.select_by_label(cols)
    except TypeError:
        raise TypeError(
            "Column indices must be names, slices, "
            "list-like of names, or boolean mask"
        )
    if scalar:
        assert (
            len(ca) == 1
        ), "Scalar column indexer should not produce more than one column"

    return rows, (scalar, ca)


def destructure_series_loc_indexer(key: Any, frame: cudf.Series) -> Any:
    """Destructure an index key for Series loc getitem.

    Parameters
    ----------
    key
        Key to destructure
    frame
        Series for unpacking context

    Returns
    -------
    Single key that will index the rows
    """
    (rows,) = destructure_loc_key(key, frame)
    return rows


def ordered_find(needles: "ColumnBase", haystack: "ColumnBase") -> GatherMap:
    """Find locations of needles in a haystack preserving order

    Parameters
    ----------
    needles
        Labels to look for
    haystack
        Haystack to search in

    Returns
    -------
    NumericalColumn
        Integer gather map of locations needles were found in haystack

    Raises
    ------
    KeyError
        If not all needles were found in the haystack.
        If needles cannot be converted to the dtype of haystack.

    Notes
    -----
    This sorts the gather map so that the result comes back in the
    order the needles were specified (and are found in the haystack).
    """
    # Pre-process to match dtypes
    needle_kind = needles.dtype.kind
    haystack_kind = haystack.dtype.kind
    if haystack_kind == "O":
        try:
            needles = needles.astype(haystack.dtype)
        except ValueError:
            # Pandas raise KeyError here
            raise KeyError("Dtype mismatch in label lookup")
    elif needle_kind == haystack_kind or {
        haystack_kind,
        needle_kind,
    }.issubset({"i", "u", "f"}):
        needles = needles.astype(haystack.dtype)
    elif needles.dtype != haystack.dtype:
        # Pandas raise KeyError here
        raise KeyError("Dtype mismatch in label lookup")
    # Can't always do an inner join because then we can't check if we
    # had missing keys (can't check the length because the entries in
    # the needle might appear multiple times in the haystack).
    lgather, rgather = libcudf.join.join([needles], [haystack], how="left")
    (left_order,) = libcudf.copying.gather(
        [cudf.core.column.arange(len(needles), dtype=size_type_dtype)],
        lgather,
        nullify=False,
    )
    (right_order,) = libcudf.copying.gather(
        [cudf.core.column.arange(len(haystack), dtype=size_type_dtype)],
        rgather,
        nullify=True,
    )
    if right_order.null_count > 0:
        raise KeyError("Not all keys in index")
    (rgather,) = libcudf.sort.sort_by_key(
        [rgather],
        [left_order, right_order],
        [True, True],
        ["last", "last"],
        stable=True,
    )
    return GatherMap.from_column_unchecked(
        rgather, len(haystack), nullify=False
    )


def parse_single_row_loc_key(
    key: Any,
    index: cudf.BaseIndex,
) -> IndexingSpec:
    """
    Turn a single label-based row indexer into structured information.

    This converts label-based lookups into structured positional
    lookups.

    Valid values for the key are
    - a slice (endpoints are looked up)
    - a scalar label
    - a boolean mask of the same length as the index
    - a column of labels to look up (may be empty)

    Parameters
    ----------
    key
        Key for label-based row indexing
    index
        Index to act as haystack for labels

    Returns
    -------
    IndexingSpec
        Structured information for indexing

    Raises
    ------
    KeyError
        If any label is not found
    ValueError
        If labels cannot be coerced to index dtype
    """
    n = len(index)
    if isinstance(key, slice):
        # Convert label slice to index slice
        # TODO: datetime index must be handled specially (unless we go for
        # pandas 2 compatibility)
        parsed_key = index.find_label_range(key)
        if len(range(n)[parsed_key]) == 0:
            return EmptyIndexer()
        else:
            return SliceIndexer(parsed_key)
    else:
        is_scalar = _is_scalar_or_zero_d_array(key)
        if is_scalar and isinstance(key, np.ndarray):
            key = cudf.core.column.as_column(key.item(), dtype=key.dtype)
        else:
            key = cudf.core.column.as_column(key)
        if (
            isinstance(key, cudf.core.column.CategoricalColumn)
            and index.dtype != key.dtype
        ):
            # TODO: is this right?
            key = key._get_decategorized_column()
        if is_bool_dtype(key.dtype):
            # The only easy one.
            return MaskIndexer(BooleanMask(key, n))
        elif len(key) == 0:
            return EmptyIndexer()
        else:
            # TODO: promote to Index objects, so this can handle
            # categoricals correctly?
            (haystack,) = index._columns
            if isinstance(index, cudf.DatetimeIndex):
                # Try to turn strings into datetimes
                key = cudf.core.column.as_column(key, dtype=index.dtype)
            gather_map = ordered_find(key, haystack)
            if is_scalar and len(gather_map.column) == 1:
                return ScalarIndexer(gather_map)
            else:
                return MapIndexer(gather_map)


def parse_row_loc_indexer(key: Any, index: cudf.BaseIndex) -> IndexingSpec:
    """
    Normalize to return structured information for a label-based row indexer.

    Given a label-based row indexer that has already been destructured by
    :func:`destructure_loc_key`, inspect further and produce structured
    information for indexing operations to act upon.

    Parameters
    ----------
    key
        Suitably destructured key for row indexing
    index
        Index to provide context

    Returns
    -------
    IndexingSpec
        Structured data for indexing. A tag + parsed data.

    Raises
    ------
    KeyError
        If a valid type of indexer is provided, but not all keys are
        found
    TypeError
        If the indexing key is otherwise invalid.
    """
    # TODO: multiindices need to be treated separately
    if key is Ellipsis:
        # Ellipsis is handled here because multiindex level-based
        # indices don't handle ellipsis in pandas.
        return SliceIndexer(slice(None))
    else:
        return parse_single_row_loc_key(key, index)
