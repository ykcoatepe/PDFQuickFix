#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${XCODEBUILD_LOG_DIR:-${ROOT_DIR}/build/logs}"
CLANG_WRAPPER="${ROOT_DIR}/scripts/clang-wrapper.sh"

export AUTO_ACTIVATED_VENV="${AUTO_ACTIVATED_VENV:-0}"

compiler_overrides=()
if [[ "${XCODEBUILD_USE_CLANG_WRAPPER:-1}" != "0" && -x "${CLANG_WRAPPER}" ]]; then
    # Xcode 26.4 can deadlock during compiler macro probing when clang is invoked with
    # `-v -E -dM`; the wrapper strips `-v` for that probe only.
    compiler_overrides=(
        "CC=${CLANG_WRAPPER}"
        "CPLUSPLUS=${CLANG_WRAPPER}"
    )
fi

mkdir -p "${LOG_DIR}"

timestamp="$(date +"%Y%m%d-%H%M%S")"
log_file="${LOG_DIR}/xcodebuild-${timestamp}.log"

if [[ -t 1 ]]; then
    if command -v xcpretty >/dev/null 2>&1; then
        set -o pipefail
        xcodebuild "${compiler_overrides[@]}" "$@" | xcpretty
    else
        xcodebuild "${compiler_overrides[@]}" "$@"
    fi
    exit 0
fi

status=0
xcodebuild "${compiler_overrides[@]}" "$@" >"${log_file}" 2>&1 || status=$?

if [[ ${status} -ne 0 ]]; then
    cat "${log_file}"
    echo "❌ xcodebuild failed. Full log: ${log_file}" >&2
    exit "${status}"
fi

tail -n "${XCODEBUILD_LOG_TAIL_LINES:-60}" "${log_file}"
echo "📄 xcodebuild log: ${log_file}"
