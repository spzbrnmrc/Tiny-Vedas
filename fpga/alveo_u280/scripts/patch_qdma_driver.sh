#!/usr/bin/env bash
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Clone/checkout Xilinx dma_ip_drivers @ 2023.2.1 and apply Tiny-Vedas
# Linux 6.8+ compatibility shims needed to build on Ubuntu 24.04.
#
# Usage:
#   ./patch_qdma_driver.sh [/path/to/dma_ip_drivers]
#   ./patch_qdma_driver.sh --build [/path/to/dma_ip_drivers]
#   ./patch_qdma_driver.sh --install [/path/to/dma_ip_drivers]
#
# Default clone path: <repo>/deps/dma_ip_drivers

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOARD_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd "${BOARD_DIR}/../.." && pwd)
PATCH="${BOARD_DIR}/patches/qdma-2023.2.1-linux-6.8.patch"
QDMA_REF="2023.2.1"
QDMA_URL="https://github.com/Xilinx/dma_ip_drivers.git"

DO_BUILD=0
DO_INSTALL=0
DRIVER_ROOT=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --build) DO_BUILD=1; shift ;;
    --install) DO_BUILD=1; DO_INSTALL=1; shift ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage 1
      ;;
    *)
      DRIVER_ROOT=$1
      shift
      ;;
  esac
done

if [[ ! -f "${PATCH}" ]]; then
  echo "error: missing patch ${PATCH}" >&2
  exit 1
fi

if [[ -z "${DRIVER_ROOT}" ]]; then
  DRIVER_ROOT="${REPO_ROOT}/deps/dma_ip_drivers"
fi

DRIVER_ROOT=$(cd / && realpath -m "${DRIVER_ROOT}")

echo "==> QDMA driver root: ${DRIVER_ROOT}"
echo "==> Target ref:       ${QDMA_REF}"
echo "==> Patch:            ${PATCH}"

if [[ ! -d "${DRIVER_ROOT}/.git" ]]; then
  echo "==> Cloning ${QDMA_URL}"
  mkdir -p "$(dirname "${DRIVER_ROOT}")"
  git clone "${QDMA_URL}" "${DRIVER_ROOT}"
fi

cd "${DRIVER_ROOT}"
git fetch --tags origin >/dev/null 2>&1 || true

# Detach to the release tip (works for tag or branch name).
if git rev-parse --verify "refs/tags/${QDMA_REF}" >/dev/null 2>&1; then
  git checkout -f "tags/${QDMA_REF}"
elif git rev-parse --verify "refs/remotes/origin/${QDMA_REF}" >/dev/null 2>&1; then
  git checkout -f -B "${QDMA_REF}" "origin/${QDMA_REF}"
elif git rev-parse --verify "refs/heads/${QDMA_REF}" >/dev/null 2>&1; then
  git checkout -f "${QDMA_REF}"
else
  echo "error: cannot find ref ${QDMA_REF} in ${DRIVER_ROOT}" >&2
  exit 1
fi

# Restore stock files then apply so re-runs are idempotent.
git checkout -f HEAD -- \
  QDMA/linux-kernel/driver/src/cdev.c \
  QDMA/linux-kernel/driver/src/cdev.h

echo "==> Applying Linux 6.8+ compatibility patch"
if patch -p1 --dry-run < "${PATCH}" >/dev/null; then
  patch -p1 < "${PATCH}"
else
  echo "error: patch does not apply cleanly to ${QDMA_REF}" >&2
  echo "       Are you on the correct dma_ip_drivers ref?" >&2
  exit 1
fi

echo "==> Patch applied."

if [[ "${DO_BUILD}" -eq 1 ]]; then
  echo "==> Building driver (make -j1 — parallel PF/VF builds race)"
  make -C QDMA/linux-kernel -j1
fi

if [[ "${DO_INSTALL}" -eq 1 ]]; then
  echo "==> Installing modules and apps (sudo)"
  sudo make -C QDMA/linux-kernel install-mods
  sudo make -C QDMA/linux-kernel install-apps
  echo "==> Done. Reload with:"
  echo "    sudo rmmod qdma-pf 2>/dev/null || true"
  echo "    sudo modprobe qdma-pf"
  echo "    dmesg | tail -30"
fi

echo "==> Driver tree ready at ${DRIVER_ROOT}"
