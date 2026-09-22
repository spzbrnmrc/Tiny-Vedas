# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Pack compile-time tensors into the AXI DRAM stub image."""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Sequence, Tuple


def _align4(n: int) -> int:
    return (int(n) + 3) & ~3


class DramImage:
    """Byte-addressed DRAM contents, emitted as sparse ``$readmemh`` words."""

    def __init__(self, base: int = 0x40000000, limit: int = 0) -> None:
        self.base = int(base)
        self.limit = int(limit)
        self.cursor = 0
        self.bytes = bytearray()
        self.holes: List[Tuple[int, int]] = []

    def _grow(self, need: int) -> None:
        if self.limit and need > self.limit:
            raise RuntimeError(
                f"DRAM image {need} bytes exceeds stub limit {self.limit} "
                f"(0x{self.limit:x})"
            )
        if len(self.bytes) < need:
            self.bytes.extend(b"\x00" * (need - len(self.bytes)))

    def _align_cursor(self) -> None:
        self.cursor = _align4(self.cursor)
        self._grow(self.cursor)

    def alloc(self, nbytes: int) -> int:
        nbytes = _align4(int(nbytes))
        for i, (off, sz) in enumerate(self.holes):
            if sz >= nbytes:
                self.holes.pop(i)
                rem = sz - nbytes
                if rem >= 4:
                    self.holes.append((off + nbytes, rem))
                return off
        self._align_cursor()
        off = self.cursor
        self.cursor += nbytes
        self._grow(self.cursor)
        return off

    def free(self, off: int, nbytes: int) -> None:
        nbytes = _align4(int(nbytes))
        if nbytes <= 0:
            return
        self.holes.append((int(off), nbytes))

    def write_i32(self, values: Sequence[int]) -> int:
        off = self.alloc(len(values) * 4)
        for i, v in enumerate(values):
            start = off + i * 4
            self.bytes[start : start + 4] = (int(v) & 0xFFFFFFFF).to_bytes(
                4, "little", signed=False
            )
        return off

    def write_i8(self, values: Sequence[int]) -> int:
        off = self.alloc(len(values))
        for i, v in enumerate(values):
            self.bytes[off + i] = int(v) & 0xFF
        return off

    def write_hex(self, path: Path) -> None:
        words: Dict[int, int] = {}
        blob = self.bytes
        for i in range(0, len(blob), 4):
            chunk = blob[i : i + 4]
            if len(chunk) < 4:
                chunk = chunk + b"\x00" * (4 - len(chunk))
            word = int.from_bytes(chunk, "little")
            if word:
                words[i // 4] = word
        lines: List[str] = ["// PyVedas DRAM stub image (word index from DRAM_BASE)"]
        for idx in sorted(words):
            lines.append(f"@{idx:x}")
            lines.append(f"{words[idx]:08x}")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
