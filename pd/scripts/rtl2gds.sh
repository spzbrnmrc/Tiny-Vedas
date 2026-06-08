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

ORFS_ENV="${ORFS_ROOT}/env.sh"
ORFS_FLOW="${ORFS_ROOT}/flow"
ORFS_CONFIG="${REPO_ROOT}/pd/work/orfs_config.mk"

if [[ ! -f "${ORFS_ENV}" ]]; then
  echo "error: OpenROAD-flow-scripts env not found at ${ORFS_ENV}" >&2
  exit 1
fi

"${REPO_ROOT}/pd/scripts/sv2v.sh"

ORFS_WORK_HOME="${REPO_ROOT}/pd/work/orfs"
mkdir -p "${ORFS_WORK_HOME}"

echo "==> OpenROAD-flow-scripts (DESIGN_CONFIG=${ORFS_CONFIG}, WORK_HOME=${ORFS_WORK_HOME})"
# shellcheck disable=SC1090
source "${ORFS_ENV}"

# ORFS defaults WORK_HOME to the flow tree (read-only in Docker / system installs).
export WORK_HOME="${ORFS_WORK_HOME}"
make -C "${ORFS_FLOW}" DESIGN_CONFIG="${ORFS_CONFIG}" ${ORFS_TARGET:-all}
