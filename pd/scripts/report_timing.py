#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Summarize post-route timing from OpenROAD-flow-scripts reports."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
_ACTIVE_MK = _REPO / "pd" / "active.mk"
_DESIGN_NICKNAME = "tiny_vedas"
_DESIGN_VARIANT = "base"
_FINISH_STAGE = "6_finish"
_LAYOUT_IMAGES = (
    "final_all.webp",
    "final_routing.webp",
    "final_placement.webp",
    "final_congestion.webp",
    "final_worst_path.webp",
    "final_clocks.webp",
)


def _orfs_reports_dir(env: dict[str, str]) -> Path:
    orfs_root = Path(env.get("ORFS_ROOT", "/tools/OpenROAD-flow-scripts"))
    platform = env.get("PD_PLATFORM", "asap7")
    return (
        orfs_root
        / "flow"
        / "reports"
        / platform
        / _DESIGN_NICKNAME
        / _DESIGN_VARIANT
    )


def _collect_layout_images(reports_dir: Path, dest_dir: Path) -> list[Path]:
    dest_dir.mkdir(parents=True, exist_ok=True)
    copied: list[Path] = []

    for name in _LAYOUT_IMAGES:
        src = reports_dir / name
        if not src.is_file():
            continue
        dst = dest_dir / name
        shutil.copy2(src, dst)
        copied.append(dst)

    # Include any other ORFS layout snapshots not in the list above.
    copied_names = {path.name for path in copied}
    for src in sorted(reports_dir.glob("*.webp")):
        if src.name in copied_names:
            continue
        dst = dest_dir / src.name
        shutil.copy2(src, dst)
        copied.append(dst)

    return copied


def _load_active_mk() -> dict[str, str]:
    if not _ACTIVE_MK.exists():
        print(f"error: {_ACTIVE_MK} not found — run 'make config' first", file=sys.stderr)
        sys.exit(1)

    env: dict[str, str] = {}
    for line in _ACTIVE_MK.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line.startswith("export "):
            continue
        key, _, value = line.removeprefix("export ").partition("=")
        env[key.strip()] = value.strip().strip('"')
    return env


def _target_frequency_ghz(period: float, unit: str) -> float:
    if unit == "ps":
        return 1000.0 / period
    if unit == "ns":
        return 1.0 / period
    raise ValueError(f"unsupported clock unit: {unit}")


def _parse_finish_report(text: str) -> dict[str, object]:
    metrics: dict[str, object] = {}

    if m := re.search(r"wns max\s+([-\d.]+)", text):
        metrics["wns"] = float(m.group(1))
    if m := re.search(r"worst slack max\s+([-\d.]+)", text):
        metrics["worst_slack"] = float(m.group(1))
    if m := re.search(r"period_min =\s+([-\d.]+)\s+fmax =\s+([-\d.]+)", text):
        metrics["min_period"] = float(m.group(1))
        metrics["fmax_mhz"] = float(m.group(2))
    if m := re.search(
        r"finish critical path delay\n-+\n([-\d.]+)", text, re.MULTILINE
    ):
        metrics["critical_path_delay"] = float(m.group(1))

    max_section = re.search(
        r"finish report_checks -path_delay max\n-+\n(.*?\n\n\n)",
        text,
        re.DOTALL,
    )
    if max_section:
        block = max_section.group(1)
        cp: dict[str, str] = {}
        if m := re.search(r"Startpoint:\s*(.+)", block):
            cp["startpoint"] = m.group(1).strip()
        if m := re.search(r"Endpoint:\s*(.+)", block):
            cp["endpoint"] = m.group(1).strip()
        if m := re.search(r"^\s+([-\d.]+)\s+data arrival time$", block, re.MULTILINE):
            cp["data_arrival"] = m.group(1)
        if m := re.search(r"^\s+([-\d.]+)\s+data required time$", block, re.MULTILINE):
            cp["data_required"] = m.group(1)
        if m := re.search(r"^\s+([-\d.]+)\s+slack \((MET|VIOLATED)\)", block, re.MULTILINE):
            cp["slack"] = m.group(1)
            cp["status"] = m.group(2)
        metrics["critical_path"] = cp

    return metrics


def _format_summary(
    env: dict[str, str],
    report_path: Path,
    metrics: dict[str, object],
) -> str:
    period = float(env["PD_CLOCK_PERIOD"])
    unit = env["PD_CLOCK_PERIOD_UNIT"]
    target_ghz = env.get("PD_TARGET_CLOCK_GHZ", "")
    target_freq = (
        float(target_ghz)
        if target_ghz
        else _target_frequency_ghz(period, unit)
    )

    lines = [
        "Tiny-Vedas post-route timing summary",
        "====================================",
        f"Platform:        {env.get('PD_PLATFORM', '?')}",
        f"Target clock:    {target_freq:.3f} GHz ({period:g} {unit})",
        f"Report:          {report_path}",
        "",
    ]

    fmax_mhz = metrics.get("fmax_mhz")
    min_period = metrics.get("min_period")
    if isinstance(fmax_mhz, float) and isinstance(min_period, float):
        lines.extend(
            [
                "Maximum frequency (estimated from worst path)",
                "---------------------------------------------",
                f"  Fmax:          {fmax_mhz:.1f} MHz ({fmax_mhz / 1000:.3f} GHz)",
                f"  Min period:    {min_period:.2f} {unit}",
                "",
            ]
        )

    wns = metrics.get("wns")
    worst_slack = metrics.get("worst_slack")
    if isinstance(wns, float):
        met = wns >= 0
        lines.extend(
            [
                f"Timing vs {target_freq:.3f} GHz target",
                "---------------------------",
                f"  WNS:           {wns:.2f} {unit} ({'MET' if met else 'VIOLATED'})",
            ]
        )
        if isinstance(worst_slack, float):
            lines.append(f"  Worst slack:   {worst_slack:.2f} {unit}")
        if not met and isinstance(min_period, float):
            lines.append(
                f"  Note:          design needs >= {min_period:.2f} {unit} "
                f"({fmax_mhz / 1000:.3f} GHz) to close timing"
            )
        lines.append("")

    cp = metrics.get("critical_path")
    if isinstance(cp, dict) and cp:
        lines.extend(
            [
                "Setup critical path (reg → reg, worst slack)",
                "--------------------------------------------",
                f"  Start:         {cp.get('startpoint', '?')}",
                f"  End:           {cp.get('endpoint', '?')}",
            ]
        )
        if "data_arrival" in cp:
            lines.append(f"  Data arrival:  {cp['data_arrival']} {unit}")
        if "data_required" in cp:
            lines.append(f"  Data required: {cp['data_required']} {unit}")
        if "slack" in cp:
            lines.append(
                f"  Slack:         {cp['slack']} {unit} ({cp.get('status', '?')})"
            )
        cp_delay = metrics.get("critical_path_delay")
        if isinstance(cp_delay, float):
            lines.append(f"  Path delay:    {cp_delay:.2f} {unit}")
        lines.append("")
        lines.append(
            "Full path report: see 'finish report_checks -path_delay max' "
            "in the ORFS finish report."
        )

    layout_images = metrics.get("layout_images")
    if isinstance(layout_images, list) and layout_images:
        lines.extend(
            [
                "",
                "Layout images",
                "-------------",
            ]
        )
        for path in layout_images:
            lines.append(f"  {path}")

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        type=Path,
        help="Path to ORFS finish report (default: auto-detect from active.mk)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Write summary to this file (default: pd/work/timing_summary.txt)",
    )
    parser.add_argument(
        "--layout-dir",
        type=Path,
        help="Copy ORFS layout images here (default: pd/work/layout)",
    )
    parser.add_argument(
        "--no-layout",
        action="store_true",
        help="Skip copying layout images",
    )
    args = parser.parse_args()

    env = _load_active_mk()
    reports_dir = _orfs_reports_dir(env)

    report_path = args.report
    if report_path is None:
        report_path = reports_dir / f"{_FINISH_STAGE}.rpt"

    if not report_path.is_file():
        print(
            f"error: finish report not found at {report_path}\n"
            "       run 'make rtl2gds' (full flow through finish) first",
            file=sys.stderr,
        )
        return 1

    metrics = _parse_finish_report(report_path.read_text(encoding="utf-8"))

    layout_dir = None
    if not args.no_layout:
        layout_dir = args.layout_dir or (_REPO / "pd" / "work" / "layout")
        copied = _collect_layout_images(reports_dir, layout_dir)
        if copied:
            metrics["layout_images"] = copied
        else:
            print(
                f"warning: no layout images found under {reports_dir}\n"
                "         run 'make rtl2gds' through finish first",
                file=sys.stderr,
            )

    summary = _format_summary(env, report_path, metrics)
    print(summary, end="")

    out_path = args.output or (_REPO / "pd" / "work" / "timing_summary.txt")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(summary, encoding="utf-8")
    print(f"Wrote: {out_path}")
    if layout_dir is not None and metrics.get("layout_images"):
        print(f"Layout images: {layout_dir}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
