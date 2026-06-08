#!/usr/bin/env bash
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Run PD commands inside the openroad/orfs Docker image (ORFS + ASAP7 PDK).
# Installs sv2v into .local/sv2v on the host (mounted at /work in the container).
#
# Usage:
#   ORFS_TARGET=synth PD_PLATFORM=ci-asap7 ./scripts/pd_docker.sh make rtl2gds
#   ./scripts/pd_docker.sh make config PD_PLATFORM=ci-asap7
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORFS_IMAGE="${ORFS_IMAGE:-openroad/orfs:26Q2-446-g85d92b593}"
SV2V_VERSION="${SV2V_VERSION:-v0.0.13}"
WORK_MOUNT="/work"

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found — install Docker to run PD in a container"

ensure_sv2v() {
    local sv2v_bin="${REPO_ROOT}/.local/sv2v/bin/sv2v"
    if [[ -x "${sv2v_bin}" ]]; then
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "curl required to download sv2v"
    command -v unzip >/dev/null 2>&1 || die "unzip required to install sv2v"

    log "Installing sv2v ${SV2V_VERSION} to .local/sv2v/bin..."
    mkdir -p "${REPO_ROOT}/.local/sv2v/bin" "${REPO_ROOT}/deps"
    local zip="${REPO_ROOT}/deps/sv2v-${SV2V_VERSION}.zip"
    curl -fL "https://github.com/zachjs/sv2v/releases/download/${SV2V_VERSION}/sv2v-Linux.zip" \
        -o "${zip}"
    unzip -o "${zip}" -d "${REPO_ROOT}/.local/sv2v/bin"
    chmod +x "${sv2v_bin}"
    [[ -x "${sv2v_bin}" ]] || die "sv2v install failed — ${sv2v_bin} not executable"
    log "sv2v installed: $("${sv2v_bin}" --version 2>&1 | head -1 || true)"
}

ensure_sv2v

if [[ $# -eq 0 ]]; then
    die "usage: $0 <command> [args...]"
fi

log "ORFS image: ${ORFS_IMAGE}"
docker run --rm \
    -v "${REPO_ROOT}:${WORK_MOUNT}" \
    -w "${WORK_MOUNT}" \
    -u "$(id -u):$(id -g)" \
    -e "ORFS_TARGET=${ORFS_TARGET:-}" \
    -e "PD_PLATFORM=${PD_PLATFORM:-ci-asap7}" \
    -e "HW_CONFIG=${HW_CONFIG:-hw/presets/rv32im_scalar.yaml}" \
    "${ORFS_IMAGE}" \
    bash -euxo pipefail -c '
        python3 -m pip install --user -q pyyaml
        cd "'"${WORK_MOUNT}"'"
        exec "$@"
    ' -- "$@"
