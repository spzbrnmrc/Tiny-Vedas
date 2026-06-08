#!/usr/bin/env bash
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Build sv2v from source into deps/sv2v (same layout as upstream: bin/sv2v).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SV2V_SRC="${REPO_ROOT}/deps/sv2v"
SV2V_BIN="${SV2V_SRC}/bin/sv2v"
SV2V_TAG="${SV2V_TAG:-v0.0.13}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

is_ubuntu() {
    [[ -f /etc/os-release ]] && grep -qiE 'ubuntu|debian' /etc/os-release
}

ensure_stack() {
    if command -v stack >/dev/null 2>&1; then
        return 0
    fi

    if is_ubuntu && command -v apt-get >/dev/null 2>&1; then
        log "Installing haskell-stack (requires sudo)..."
        sudo apt-get update
        sudo apt-get install -y haskell-stack
        command -v stack >/dev/null || die "haskell-stack install failed"
        return 0
    fi

    local stack_bin="${REPO_ROOT}/.local/bin"
    if [[ -x "${stack_bin}/stack" ]]; then
        export PATH="${stack_bin}:${PATH}"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "curl required to install Haskell Stack"
    log "Installing Haskell Stack to ${stack_bin}..."
    mkdir -p "${stack_bin}"
    curl -sSL https://get.haskellstack.org/ | sh -s - -d "${stack_bin}"
    export PATH="${stack_bin}:${PATH}"
    command -v stack >/dev/null || die "Stack install failed"
}

install_sv2v() {
    if [[ -x "${SV2V_BIN}" && "${FORCE_SV2V_REBUILD:-0}" != "1" ]]; then
        log "sv2v already built at ${SV2V_BIN} — skipping."
        log "Set FORCE_SV2V_REBUILD=1 to rebuild from source."
        return 0
    fi

    ensure_stack
    mkdir -p "${REPO_ROOT}/deps"

    if [[ ! -d "${SV2V_SRC}/.git" ]]; then
        git clone https://github.com/zachjs/sv2v "${SV2V_SRC}"
    else
        git -C "${SV2V_SRC}" fetch --tags origin
    fi

    git -C "${SV2V_SRC}" checkout "${SV2V_TAG}"

    log "Building sv2v ${SV2V_TAG} (this may take several minutes on first build)..."
    make -C "${SV2V_SRC}"

    [[ -x "${SV2V_BIN}" ]] || die "sv2v build failed — ${SV2V_BIN} not found."
    log "sv2v built: $("${SV2V_BIN}" --version 2>&1 | head -1 || true)"
}

install_sv2v
