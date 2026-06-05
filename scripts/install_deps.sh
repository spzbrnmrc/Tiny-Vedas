#!/usr/bin/env bash
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Install Tiny-Vedas development dependencies:
#   - Ubuntu build packages (build-essential, Verilator build deps)
#   - Python virtual environment + pip packages
#   - Prebuilt RISC-V GNU bare-metal toolchain (riscv64-unknown-elf-gcc)
#   - Latest stable Verilator built from source into .local/verilator
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${REPO_ROOT}/venv"
VERILATOR_PREFIX="${REPO_ROOT}/.local/verilator"
VERILATOR_SRC="${REPO_ROOT}/deps/verilator"
VERILATOR_BIN="${VERILATOR_PREFIX}/bin/verilator"
RISCV_PREFIX="${REPO_ROOT}/.local/riscv"
RISCV_GCC="${RISCV_PREFIX}/bin/riscv64-unknown-elf-gcc"
# Pin for reproducible CI/local installs; override with RISCV_TOOLCHAIN_VERSION=...
RISCV_TOOLCHAIN_VERSION="${RISCV_TOOLCHAIN_VERSION:-2026.06.05}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

is_ubuntu() {
    [[ -f /etc/os-release ]] && grep -qiE 'ubuntu|debian' /etc/os-release
}

install_apt_packages() {
    if ! is_ubuntu; then
        warn "Not Ubuntu/Debian — skipping apt package installation."
        warn "Install build-essential, git, autoconf, flex, bison, libfl-dev,"
        warn "help2man, perl, zlib1g-dev, and python3-venv manually, then re-run."
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "apt-get not found. Install system build dependencies manually."
    fi

    log "Installing Ubuntu packages (requires sudo)..."
    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        git \
        autoconf \
        flex \
        bison \
        libfl-dev \
        help2man \
        perl \
        zlib1g-dev \
        curl \
        wget \
        xz-utils \
        python3 \
        python3-pip \
        python3-venv
}

detect_ubuntu_series() {
    if [[ ! -f /etc/os-release ]]; then
        echo "22.04"
        return
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${VERSION_ID:-}" in
        24.04|24.10) echo "24.04" ;;
        22.04|22.10) echo "22.04" ;;
        *) warn "Unsupported Ubuntu ${VERSION_ID:-unknown}; defaulting to 22.04 toolchain."; echo "22.04" ;;
    esac
}

install_riscv_toolchain() {
    if [[ -x "${RISCV_GCC}" && "${FORCE_RISCV_TOOLCHAIN_REINSTALL:-0}" != "1" ]]; then
        log "RISC-V toolchain already installed at ${RISCV_GCC} — skipping download."
        log "Set FORCE_RISCV_TOOLCHAIN_REINSTALL=1 to reinstall."
        return 0
    fi

    local ubuntu_series archive_name url tmp_archive
    ubuntu_series="$(detect_ubuntu_series)"
    archive_name="riscv64-elf-ubuntu-${ubuntu_series}-gcc.tar.xz"
    url="https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/${archive_name}"

    log "Installing RISC-V bare-metal toolchain (${RISCV_TOOLCHAIN_VERSION}, Ubuntu ${ubuntu_series})..."
    mkdir -p "${REPO_ROOT}/deps" "${REPO_ROOT}/.local"
    tmp_archive="${REPO_ROOT}/deps/${archive_name}"

    if command -v curl >/dev/null 2>&1; then
        curl -fL "${url}" -o "${tmp_archive}"
    else
        wget -O "${tmp_archive}" "${url}"
    fi

    rm -rf "${RISCV_PREFIX}"
    tar -xJf "${tmp_archive}" -C "${REPO_ROOT}/.local"

    [[ -x "${RISCV_GCC}" ]] || die "RISC-V toolchain install failed — ${RISCV_GCC} not found."

    log "Verifying RV32IM support..."
    printf 'int main(void) { return 0; }\n' > "${REPO_ROOT}/deps/rv32_smoke.c"
    "${RISCV_GCC}" -march=rv32im -mabi=ilp32 -nostdlib -o "${REPO_ROOT}/deps/rv32_smoke.elf" \
        "${REPO_ROOT}/deps/rv32_smoke.c"
    rm -f "${REPO_ROOT}/deps/rv32_smoke.c" "${REPO_ROOT}/deps/rv32_smoke.elf"

    log "RISC-V toolchain installed: $("${RISCV_GCC}" --version | head -1)"
}

install_python_venv() {
    log "Setting up Python virtual environment at ${VENV_DIR}..."
    if [[ ! -d "${VENV_DIR}" ]]; then
        python3 -m venv "${VENV_DIR}"
    fi
    # shellcheck source=/dev/null
    source "${VENV_DIR}/bin/activate"
    python -m pip install --upgrade pip
    python -m pip install -r "${REPO_ROOT}/requirements.txt"
    if [[ -f "${REPO_ROOT}/pyvedas/requirements.txt" ]]; then
        log "Installing PyVedas dependencies (CPU PyTorch)..."
        python -m pip install -r "${REPO_ROOT}/pyvedas/requirements.txt" \
            --index-url https://download.pytorch.org/whl/cpu
    fi
    log "Python dependencies installed."
}

install_verilator() {
    if [[ -x "${VERILATOR_BIN}" && "${FORCE_VERILATOR_REBUILD:-0}" != "1" ]]; then
        log "Verilator already installed at ${VERILATOR_BIN} — skipping build."
        log "Set FORCE_VERILATOR_REBUILD=1 to rebuild from source."
        return 0
    fi

    log "Building latest stable Verilator from source..."
    mkdir -p "${REPO_ROOT}/deps" "${REPO_ROOT}/.local"

    if [[ ! -d "${VERILATOR_SRC}/.git" ]]; then
        git clone https://github.com/verilator/verilator "${VERILATOR_SRC}"
    else
        git -C "${VERILATOR_SRC}" fetch --tags origin
    fi

    # Track the latest stable release branch maintained by the Verilator project.
    # Override with VERILATOR_TAG=v5.048 (or similar) to pin a specific release.
    if [[ -n "${VERILATOR_TAG:-}" ]]; then
        git -C "${VERILATOR_SRC}" checkout "${VERILATOR_TAG}"
    else
        git -C "${VERILATOR_SRC}" checkout stable
        git -C "${VERILATOR_SRC}" pull --ff-only origin stable
    fi

    # Verilator must be configured and built in-tree; out-of-tree builds break
    # the AST/codegen rules (e.g. V3AstNodeDType.h, vlcovgen).
    pushd "${VERILATOR_SRC}" >/dev/null

    # Remove artifacts from any previous out-of-tree or failed build.
    rm -rf build
    if [[ -f Makefile ]]; then
        make distclean >/dev/null 2>&1 || true
    fi

    unset VERILATOR_ROOT

    log "Running autoconf..."
    autoconf

    log "Configuring Verilator (prefix: ${VERILATOR_PREFIX})..."
    ./configure --prefix="${VERILATOR_PREFIX}"

    log "Compiling Verilator (this may take several minutes)..."
    make -j"$(nproc)"

    log "Installing Verilator to ${VERILATOR_PREFIX}..."
    make install

    popd >/dev/null

    [[ -x "${VERILATOR_BIN}" ]] || die "Verilator install failed — ${VERILATOR_BIN} not found."
    log "Verilator installed: $("${VERILATOR_BIN}" --version | head -1)"
}

write_env_script() {
    local env_file="${REPO_ROOT}/scripts/env.sh"
    log "Writing environment script to ${env_file}..."
    cat >"${env_file}" <<'EOF'
# Generated by scripts/install_deps.sh — do not edit.
# Source this file or use scripts/with_env.sh / make targets.
EOF
    cat >>"${env_file}" <<EOF
REPO_ROOT="${REPO_ROOT}"
VENV_BIN="${VENV_DIR}/bin"
RISCV_BIN="${RISCV_PREFIX}/bin"
VERILATOR_BIN="${VERILATOR_PREFIX}/bin"

unset VERILATOR_ROOT
export VIRTUAL_ENV="${VENV_DIR}"

# Do not use venv/bin/activate here — its deactivate() restores a stale PATH
# and drops the toolchain prefixes when the venv is already active.
_strip_known_paths() {
    local entry
    local -a parts=()
    local IFS=:
    for entry in \${PATH}; do
        [[ -z "\${entry}" ]] && continue
        [[ "\${entry}" == "\${VENV_BIN}" ]] && continue
        [[ "\${entry}" == "\${RISCV_BIN}" ]] && continue
        [[ "\${entry}" == "\${VERILATOR_BIN}" ]] && continue
        parts+=("\${entry}")
    done
    PATH="\$(IFS=:; echo "\${parts[*]}")"
}

_strip_known_paths
export PATH="\${VENV_BIN}:\${RISCV_BIN}:\${VERILATOR_BIN}:\${PATH}"

hash -r 2>/dev/null || true
EOF
    chmod +x "${env_file}"
}

verify_toolchain() {
    log "Verifying installed tools..."
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/env.sh"

    command -v riscv64-unknown-elf-gcc >/dev/null || die "riscv64-unknown-elf-gcc not on PATH"
    command -v verilator >/dev/null || die "verilator not on PATH"
    command -v python >/dev/null || die "python not on PATH (venv activation failed)"

    riscv64-unknown-elf-gcc --version | head -1
    verilator --version | head -1
    python --version

    log "Toolchain verification passed."
}

main() {
    cd "${REPO_ROOT}"
    install_apt_packages
    install_python_venv
    install_riscv_toolchain
    install_verilator
    write_env_script
    verify_toolchain
    log "Done. Use ./scripts/with_env.sh <cmd> or make smoke-verilator (PATH and venv are applied automatically)."
}

main "$@"
