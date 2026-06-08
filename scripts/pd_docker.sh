#!/usr/bin/env bash
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Run PD commands inside the openroad/orfs Docker image (ORFS + ASAP7 PDK).
# Builds sv2v from source into deps/sv2v on the host (mounted at /work/deps).
#
# Usage:
#   ORFS_TARGET=synth PD_PLATFORM=ci-asap7 ./scripts/pd_docker.sh make rtl2gds
#   ./scripts/pd_docker.sh make config PD_PLATFORM=ci-asap7
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORFS_IMAGE="${ORFS_IMAGE:-openroad/orfs:26Q2-446-g85d92b593}"
WORK_MOUNT="/work"

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found — install Docker to run PD in a container"

"${REPO_ROOT}/scripts/install_sv2v.sh"

if [[ $# -eq 0 ]]; then
    die "usage: $0 <command> [args...]"
fi

log "ORFS image: ${ORFS_IMAGE}"
docker run --rm \
    -v "${REPO_ROOT}:${WORK_MOUNT}" \
    -w "${WORK_MOUNT}" \
    -u "$(id -u):$(id -g)" \
    -e "HOME=${WORK_MOUNT}/.cache/home" \
    -e "ORFS_TARGET=${ORFS_TARGET:-}" \
    -e "PD_PLATFORM=${PD_PLATFORM:-ci-asap7}" \
    -e "HW_CONFIG=${HW_CONFIG:-hw/presets/rv32im_scalar.yaml}" \
    -e "WORK_HOME=${WORK_MOUNT}/pd/work/orfs" \
    -e "FLOW_HOME=/OpenROAD-flow-scripts/flow" \
    "${ORFS_IMAGE}" \
    bash -euxo pipefail -c '
        mkdir -p "${HOME}"
        python3 -m pip install --user -q pyyaml
        cd "'"${WORK_MOUNT}"'"
        exec "$@"
    ' -- "$@"
