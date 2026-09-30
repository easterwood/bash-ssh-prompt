#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Runs every test script in this directory and reports a summary.
# Exit code 0 means all of them passed.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

failed=0
total=0

for script in *.sh; do
    # lib.sh is sourced by the tests, not run.
    [[ $script != lib.sh && $script != run-all.sh ]] || continue

    total=$((total + 1))
    if ! bash "$script"; then
        failed=$((failed + 1))
    fi
done

printf '\n'
if (( failed )); then
    printf '%d of %d test scripts failed.\n' "$failed" "$total" >&2
    exit 1
fi

printf 'All %d test scripts passed.\n' "$total"
