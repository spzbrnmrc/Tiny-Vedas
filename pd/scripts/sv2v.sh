#!/usr/bin/env bash
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTIVE_MK="${REPO_ROOT}/pd/active.mk"

if [[ ! -f "${ACTIVE_MK}" ]]; then
  echo "error: ${ACTIVE_MK} not found — run 'make config' first" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ACTIVE_MK}"

if [[ ! -x "${SV2V}" ]]; then
  echo "error: sv2v not executable at ${SV2V}" >&2
  exit 1
fi

mkdir -p "$(dirname "${PD_VERILOG}")"

mapfile -t SOURCES < <(
  grep -v '^[[:space:]]*#' "${REPO_ROOT}/pd/synth.flist" | grep -v '^[[:space:]]*$' \
    | sed "s|\$PROJ|${REPO_ROOT}|g"
)

echo "==> sv2v (${#SOURCES[@]} files) -> ${PD_VERILOG}"
"${SV2V}" \
  -DSYNTHESIS \
  -I "${REPO_ROOT}/pd/include" \
  -I "${REPO_ROOT}/rtl/include" \
  -I "${REPO_ROOT}/rtl/idu" \
  --top="${PD_TOP}" \
  --write="${PD_VERILOG}" \
  "${SOURCES[@]}"

echo "==> sv2v done ($(wc -l < "${PD_VERILOG}") lines)"
