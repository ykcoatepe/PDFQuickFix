#!/usr/bin/env bash
set -euo pipefail

if ! REAL_CLANG="$(/usr/bin/xcrun --find clang 2>/dev/null)"; then
    REAL_CLANG="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
fi

has_verbose=0
has_preprocess=0
has_dump_macros=0
uses_dev_null=0

for arg in "$@"; do
    case "${arg}" in
        -v) has_verbose=1 ;;
        -E) has_preprocess=1 ;;
        -dM) has_dump_macros=1 ;;
        /dev/null) uses_dev_null=1 ;;
    esac
done

if [[ ${has_verbose} -eq 1 && ${has_preprocess} -eq 1 && ${has_dump_macros} -eq 1 && ${uses_dev_null} -eq 1 ]]; then
    filtered_args=()
    for arg in "$@"; do
        if [[ "${arg}" != "-v" ]]; then
            filtered_args+=("${arg}")
        fi
    done
    exec "${REAL_CLANG}" "${filtered_args[@]}"
fi

exec "${REAL_CLANG}" "$@"
