# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Tiny-Vedas Alveo U280 — BAR2 (AXI-Lite) host access via PCI sysfs mmap."""

from __future__ import annotations

import mmap
import os
import struct
import time
from pathlib import Path
from typing import Iterable, Optional

XILINX_VENDOR = 0x10EE
QDMA_DEVICE = 0x903F

# BAR2 map (2 MiB): CTRL@0, ICCM@0x1000 (32KiB), DCCM@0x9000 (1MiB)
CTRL_BASE = 0x0000
ICCM_BASE = 0x1000
ICCM_SIZE = 0x8000
DCCM_BASE = 0x9000
DCCM_SIZE = 0x100000
BAR2_SIZE = 0x200000

REG_VERSION = 0x00
REG_SCRATCH = 0x04
REG_HEARTBEAT = 0x08
REG_CORE_CTRL = 0x0C
REG_RESET_VECTOR = 0x10
REG_EOT_STATUS = 0x14
REG_EOT_CLEAR = 0x18
REG_UART_STATUS = 0x1C
REG_UART_POP = 0x20
REG_UART_CLEAR = 0x24
REG_DRAM_WIN = 0x28
REG_DRAM_SEL = 0x2C

VERSION_SLICE_B = 0x000B0014
LINK_BASE = 0x00100000
DEFAULT_RESET_VECTOR = LINK_BASE


def find_qdma_bdf(vendor: int = XILINX_VENDOR, device: int = QDMA_DEVICE) -> str:
    sysfs = Path("/sys/bus/pci/devices")
    for p in sorted(sysfs.iterdir()):
        try:
            vend = int((p / "vendor").read_text().strip(), 16)
            dev = int((p / "device").read_text().strip(), 16)
        except OSError:
            continue
        if vend == vendor and dev == device:
            return p.name
    raise FileNotFoundError(
        f"No PCI device {vendor:04x}:{device:04x} — program bitstream and rescan?"
    )


class VedasBar2:
    """Memory-mapped BAR2. Needs root (or CAP_SYS_RAWIO) for /sys/.../resource2."""

    def __init__(self, bdf: Optional[str] = None, bar: int = 2):
        self.bdf = bdf or find_qdma_bdf()
        self.resource = Path(f"/sys/bus/pci/devices/{self.bdf}/resource{bar}")
        if not self.resource.exists():
            raise FileNotFoundError(self.resource)
        self.size = self.resource.stat().st_size
        self._fd = os.open(self.resource, os.O_RDWR | os.O_SYNC)
        self._mm = mmap.mmap(
            self._fd, self.size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE
        )

    def close(self) -> None:
        if self._mm is not None:
            self._mm.close()
            self._mm = None
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def __enter__(self) -> "VedasBar2":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def require_bar_size(self, min_size: int = BAR2_SIZE) -> None:
        if self.size < min_size:
            raise RuntimeError(
                f"BAR2 is {self.size} bytes (need >= {min_size}). "
                f"Program Slice B bitstream, then PCIe remove/rescan."
            )

    def read32(self, off: int) -> int:
        if off < 0 or off + 4 > self.size:
            raise ValueError(f"offset 0x{off:x} out of BAR2 (size 0x{self.size:x})")
        return struct.unpack_from("<I", self._mm, off)[0]

    def write32(self, off: int, val: int) -> None:
        if off < 0 or off + 4 > self.size:
            raise ValueError(f"offset 0x{off:x} out of BAR2 (size 0x{self.size:x})")
        struct.pack_into("<I", self._mm, off, val & 0xFFFFFFFF)

    def read_bytes(self, off: int, n: int) -> bytes:
        return bytes(self._mm[off : off + n])

    def write_bytes(self, off: int, data: bytes) -> None:
        """Write bytes to BAR2.

        ICCM/DCCM go through AXI-Lite CDC with backpressure. A bulk mmap
        store is posted on PCIe and silently drops under load — word writes
        plus a non-posted read drain are required for large images.
        """
        end = off + len(data)
        if off < 0 or end > self.size:
            raise ValueError(f"write [{off:#x},{end:#x}) out of BAR2")

        mem = off >= ICCM_BASE and end <= (DCCM_BASE + DCCM_SIZE)
        if not mem:
            self._mm[off:end] = data
            return

        i = 0
        n = len(data)
        while i + 4 <= n:
            struct.pack_into("<I", self._mm, off + i, struct.unpack_from("<I", data, i)[0])
            i += 4
            # Non-posted read forces PCIe to flush posted writes to the device.
            if (i & 0xF) == 0:
                self.read32(REG_VERSION)
        if i < n:
            # Rare unaligned tail — RMW via read32/write32
            for j in range(i, n):
                self._mm[off + j] = data[j]
            self.read32(REG_VERSION)
        else:
            self.read32(REG_VERSION)

    def version(self) -> int:
        return self.read32(REG_VERSION)

    def heartbeat(self) -> int:
        return self.read32(REG_HEARTBEAT)

    def core_ctrl(self) -> int:
        return self.read32(REG_CORE_CTRL)

    def mmcm_locked(self) -> bool:
        return bool(self.core_ctrl() & 0x2)

    def core_run(self) -> bool:
        return bool(self.core_ctrl() & 0x1)

    def set_core_run(self, run: bool) -> None:
        self.write32(REG_CORE_CTRL, 1 if run else 0)

    def set_reset_vector(self, addr: int = DEFAULT_RESET_VECTOR) -> None:
        self.write32(REG_RESET_VECTOR, addr & 0xFFFFFFFF)

    def eot_done(self) -> bool:
        return bool(self.read32(REG_EOT_STATUS) & 0x1)

    def clear_eot(self) -> None:
        self.write32(REG_EOT_CLEAR, 1)

    def clear_uart(self) -> None:
        self.write32(REG_UART_CLEAR, 1)

    def uart_status(self) -> tuple[int, bool, bool]:
        s = self.read32(REG_UART_STATUS)
        level = s & 0xFFFF
        empty = bool(s & (1 << 16))
        full = bool(s & (1 << 17))
        return level, empty, full

    def pop_uart(self, max_bytes: int = 4096) -> bytes:
        out = bytearray()
        for _ in range(max_bytes):
            _, empty, _ = self.uart_status()
            if empty:
                break
            w = self.read32(REG_UART_POP)
            if w == 0xFFFFFFFF:
                break
            out.append(w & 0xFF)
        return bytes(out)

    def wait_mmcm_locked(self, timeout_s: float = 5.0) -> None:
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            if self.mmcm_locked():
                return
            time.sleep(0.01)
        raise TimeoutError("MMCM (core_clk) did not lock")

    def halt(self) -> None:
        self.set_core_run(False)
        time.sleep(0.001)

    def load_iccm(self, data: bytes, link_addr: int = LINK_BASE) -> None:
        if self.core_run():
            raise RuntimeError("core_run=1 — halt before loading ICCM")
        if link_addr < LINK_BASE:
            raise ValueError("link_addr below default link base")
        byte_off = (link_addr - LINK_BASE) & (ICCM_SIZE - 1)
        if byte_off + len(data) > ICCM_SIZE:
            raise ValueError(
                f"ICCM image {len(data)}B @ off {byte_off} exceeds {ICCM_SIZE}B window"
            )
        self.write_bytes(ICCM_BASE + byte_off, data)

    def load_iccm_words(self, words: Iterable[int], word_index: int = 0) -> None:
        if self.core_run():
            raise RuntimeError("core_run=1 — halt before loading ICCM")
        payload = b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in words)
        self.write_bytes(ICCM_BASE + word_index * 4, payload)

    def load_dccm(self, data: bytes, offset: int = 0) -> None:
        if self.core_run():
            raise RuntimeError("core_run=1 — halt before loading DCCM")
        if offset + len(data) > DCCM_SIZE:
            raise ValueError("DCCM image exceeds window")
        self.write_bytes(DCCM_BASE + offset, data)

    def set_dram_window(self, byte_off: int, enable: bool) -> None:
        if self.core_run():
            raise RuntimeError("core_run=1 — halt before remapping DCCM onto DRAM")
        self.write32(REG_DRAM_WIN, byte_off & 0xFFFFFFFF)
        self.write32(REG_DRAM_SEL, 1 if enable else 0)

    def has_dram_window(self) -> bool:
        """True when CTRL 0x28/0x2C are the DRAM remap (not 0xdeadbeef)."""
        self.halt()
        self.write32(REG_DRAM_WIN, 0x12340000)
        got = self.read32(REG_DRAM_WIN)
        self.write32(REG_DRAM_WIN, 0)
        self.write32(REG_DRAM_SEL, 0)
        return got == 0x12340000

    def load_dram(self, data: bytes, *, window: int = DCCM_SIZE) -> None:
        """Chunked halt-and-load of the DRAM stub through the DCCM BAR window."""
        self.load_dram_range(data, 0, window=window)

    def load_dram_range(
        self, data: bytes, offset: int = 0, *, window: int = DCCM_SIZE
    ) -> None:
        """Chunked halt-and-load at a DRAM-stub byte offset."""
        if self.core_run():
            raise RuntimeError("core_run=1 — halt before loading DRAM")
        try:
            i = 0
            n = len(data)
            t0 = time.time()
            last = -1
            while i < n:
                chunk = data[i : i + window]
                self.set_dram_window(int(offset) + i, True)
                self.write_bytes(DCCM_BASE, chunk)
                i += len(chunk)
                pct = (100 * i) // n if n else 100
                if pct >= last + 10 or i >= n:
                    last = pct
                    print(
                        f"[dram] wrote {i}/{n}B ({pct}%) in {time.time()-t0:.1f}s",
                        flush=True,
                    )
        finally:
            self.set_dram_window(0, False)

    def read_dram(self, nbytes: int, offset: int = 0, *, window: int = DCCM_SIZE) -> bytes:
        """Chunked halt-and-read of the DRAM stub through the DCCM BAR window."""
        if self.core_run():
            raise RuntimeError("core_run=1 — halt before reading DRAM")
        out = bytearray()
        try:
            off = int(offset)
            end = off + int(nbytes)
            while off < end:
                self.set_dram_window(off, True)
                n = min(window, end - off)
                # Word reads + drain, same CDC constraint as writes.
                i = 0
                while i + 4 <= n:
                    out.extend(struct.pack("<I", self.read32(DCCM_BASE + i)))
                    i += 4
                    if (i & 0xF) == 0:
                        self.read32(REG_VERSION)
                if i < n:
                    tail = self.read_bytes(DCCM_BASE + i, n - i)
                    out.extend(tail)
                    self.read32(REG_VERSION)
                off += n
        finally:
            self.set_dram_window(0, False)
        return bytes(out)

    def run_and_wait_eot(self, timeout_s: float = 2.0) -> float:
        self.clear_eot()
        self.clear_uart()
        time.sleep(0.001)
        self.set_core_run(True)
        t0 = time.time()
        hb0 = self.heartbeat()
        last_log = t0
        while time.time() - t0 < timeout_s:
            if self.eot_done():
                return time.time() - t0
            now = time.time()
            if now - last_log >= 2.0:
                hb = self.heartbeat()
                print(
                    f"[eot] {now-t0:.1f}s/{timeout_s:.0f}s run={int(self.core_run())} "
                    f"hb=0x{hb:08x} (+{(hb-hb0)&0xFFFFFFFF})",
                    flush=True,
                )
                last_log = now
            time.sleep(0.002)
        self.set_core_run(False)
        raise TimeoutError(f"EOT not seen within {timeout_s}s")
