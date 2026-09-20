#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Generate csr_pkg.svh + csr_file.sv from a YAML CSR table."""

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
from typing import Any

import yaml


def _hi_lo(bits: list) -> tuple[int, int]:
    if len(bits) != 2:
        raise ValueError(f"fields.bits must be [hi, lo], got {bits!r}")
    hi, lo = int(bits[0]), int(bits[1])
    if hi < lo:
        raise ValueError(f"fields.bits hi < lo: {bits!r}")
    return hi, lo


def render_pkg(data: dict[str, Any]) -> str:
    pkg = data["pkg_name"]
    lines = [
        f"// Generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} "
        "- DO NOT EDIT, REGENERATE INSTEAD",
        "",
        f"`ifndef {pkg.upper()}_SVH",
        f"`define {pkg.upper()}_SVH",
        "",
        f"package {pkg};",
    ]
    for csr in data["csrs"]:
        name = str(csr["name"]).upper()
        addr = int(csr["addr"], 0) if isinstance(csr["addr"], str) else int(csr["addr"])
        lines.append(f"  localparam logic [11:0] CSR_{name}_ADDR = 12'h{addr:03X};")
        for field in csr.get("fields", []):
            hi, lo = _hi_lo(field["bits"])
            fname = str(field["name"]).upper()
            lines.append(
                f"  localparam int CSR_{name}_{fname}_HI = {hi};"
            )
            lines.append(
                f"  localparam int CSR_{name}_{fname}_LO = {lo};"
            )
    lines += [
        f"endpackage",
        "",
        f"`endif",
        "",
    ]
    return "\n".join(lines)


def render_file(data: dict[str, Any]) -> str:
    mod = data["module_name"]
    pkg = data["pkg_name"]
    header = f"""\
// Generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} \
- DO NOT EDIT, REGENERATE INSTEAD

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef HW_CONFIG_SVH
`include "hw_config.svh"
`endif

`ifndef {pkg.upper()}_SVH
`include "{pkg}.svh"
`endif

module {mod} (
    input  logic        clk,
    input  logic        rstn,

    input  logic        csr_req,
    input  logic        csr_write,
    input  logic [11:0] csr_addr,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,
    output logic        csr_illegal,

    input  logic        vset_we,
    input  logic [31:0] vset_vl,
    input  logic [31:0] vset_vtype,

    output logic [31:0] vl,
    output logic [31:0] vtype,
    output logic [31:0] vlenb,
    output logic [31:0] vstart
);

  import {pkg}::*;

  localparam logic [31:0] VLENB_CONST = (VLEN == 0) ? 32'd0 : 32'(VLEN / 8);

"""
    decls: list[str] = []
    resets: list[str] = []
    vset_updates = [
        "      if (vset_we) begin",
        "        vl_q    <= vset_vl;",
        "        vtype_q <= vset_vtype;",
        "        vstart_q <= 32'd0;",
        "      end",
    ]
    read_cases: list[str] = []
    decode_ok: list[str] = []

    for csr in data["csrs"]:
        name = str(csr["name"])
        uname = name.upper()
        width = int(csr.get("width", 32))
        const = bool(csr.get("const", False))
        reset = csr.get("reset", 0)
        access = str(csr.get("access", "RO")).upper()
        addr_macro = f"CSR_{uname}_ADDR"

        if const:
            decls.append(f"  logic [{width-1}:0] {name}_q;")
            if reset == "vlen_bytes":
                resets.append(f"        {name}_q <= VLENB_CONST;")
            else:
                rval = int(reset, 0) if isinstance(reset, str) else int(reset)
                resets.append(f"        {name}_q <= 32'h{rval:08X};")
        else:
            decls.append(f"  logic [{width-1}:0] {name}_q;")
            if isinstance(reset, str) and reset == "vlen_bytes":
                resets.append(f"        {name}_q <= VLENB_CONST;")
            else:
                rval = int(reset, 0) if isinstance(reset, str) else int(reset)
                resets.append(f"        {name}_q <= 32'h{rval:08X};")

        read_cases.append(f"      {addr_macro}: csr_rdata = {name}_q;")
        decode_ok.append(f"(csr_addr == {addr_macro})")

    assigns = [
        "  assign vl     = vl_q;",
        "  assign vtype  = vtype_q;",
        "  assign vlenb  = vlenb_q;",
        "  assign vstart = vstart_q;",
        "",
        "  // v1: reads of known CSRs only. A write (rs1 != x0) is illegal.",
        "  assign csr_illegal = csr_req && (csr_write || !("
        + " || ".join(decode_ok)
        + "));",
        "",
        "  always_comb begin",
        "    csr_rdata = 32'd0;",
        "    unique case (csr_addr)",
        *read_cases,
        "      default: csr_rdata = 32'd0;",
        "    endcase",
        "  end",
        "",
        "  always_ff @(posedge clk or negedge rstn) begin",
        "    if (!rstn) begin",
        *resets,
        "    end else begin",
        *vset_updates,
        "    end",
        "  end",
        "",
        "endmodule",
        "",
    ]
    unused = (
        "  logic _unused_wdata;\n"
        "  assign _unused_wdata = csr_wdata[0];\n\n"
        if False
        else ""
    )
    return header + "\n".join(decls) + "\n\n" + unused + "\n".join(assigns)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-t", "--table", required=True, help="YAML CSR table")
    parser.add_argument("-o", "--output", default="rtl/csr", help="output directory")
    args = parser.parse_args(argv)

    table = Path(args.table)
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    with table.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    pkg_name = data["pkg_name"]
    mod_name = data["module_name"]
    (out / f"{pkg_name}.svh").write_text(render_pkg(data), encoding="utf-8")
    (out / f"{mod_name}.sv").write_text(render_file(data), encoding="utf-8")
    print(f"Wrote {out / pkg_name}.svh")
    print(f"Wrote {out / mod_name}.sv")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
