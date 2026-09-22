# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""CLI: ``python -m models.yolov3_tiny {export,download,eval,calibrate}``."""

from __future__ import annotations

import argparse
import sys
from typing import List

from .calibrate import main as calibrate_main
from .card import chunk_main
from .eval_map import main as eval_main
from .export_graph import main as export_main
from .visualize import main as vis_main
from .weights import default_weights_path, download_weights


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("export", "download", "eval", "vis", "chunk", "calibrate"),
        help="export / download / eval / vis / chunk / calibrate",
    )
    args, rest = parser.parse_known_args(argv)
    if args.command == "export":
        return export_main(rest)
    if args.command == "download":
        path = download_weights(default_weights_path())
        print(path)
        return 0
    if args.command == "eval":
        return eval_main(rest)
    if args.command == "vis":
        return vis_main(rest)
    if args.command == "chunk":
        return chunk_main(rest)
    if args.command == "calibrate":
        return calibrate_main(rest)
    return 2


if __name__ == "__main__":
    sys.exit(main())
