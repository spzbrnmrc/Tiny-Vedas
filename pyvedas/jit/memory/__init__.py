# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

from .emit import emit_static_buffers, format_shape
from .materialize import (
    BufferMaterializer,
    FlatRowMajorMaterializer,
    flatten_row_major,
    resolve_element_type,
)
from .gemm_tiles import (
    GemmJob,
    choose_tile,
    matmul_out_shape,
    plan_gemm_jobs,
    scratch_budget,
    tile_scratch_bytes,
)
from .types import BufferLayout, ElementType, MemoryPlan, StaticBuffer

__all__ = [
    "BufferLayout",
    "BufferMaterializer",
    "ElementType",
    "FlatRowMajorMaterializer",
    "GemmJob",
    "MemoryPlan",
    "StaticBuffer",
    "choose_tile",
    "emit_static_buffers",
    "flatten_row_major",
    "format_shape",
    "matmul_out_shape",
    "plan_gemm_jobs",
    "resolve_element_type",
    "scratch_budget",
    "tile_scratch_bytes",
]
