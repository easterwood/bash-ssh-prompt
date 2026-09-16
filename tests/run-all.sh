#!/usr/bin/env bash

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
