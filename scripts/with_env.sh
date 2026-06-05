#!/usr/bin/env bash
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Run a command with the Tiny-Vedas toolchain environment active.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
    printf 'error: %s not found. Run `make deps` first.\n' "${ENV_FILE}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"

if [[ $# -eq 0 ]]; then
    printf 'usage: %s <command> [args...]\n' "$0" >&2
    exit 1
fi

exec "$@"
