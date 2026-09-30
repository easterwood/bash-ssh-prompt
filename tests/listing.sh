#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for bashrc.d/listing.sh (ll).
#
# ll reformats GNU ls output positionally, so the test needs GNU ls. On a
# system without it the checks are skipped rather than reported as failures.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='listing'
# shellcheck source=tests/lib.sh
source tests/lib.sh

# This greps a version banner, not a file listing.
# shellcheck disable=SC2010
if ! ls --version 2>/dev/null | grep -qi 'GNU coreutils'; then
    printf 'SKIP: %s: GNU ls is required\n' "$TEST_NAME"
    exit 0
fi

test_sandbox

# shellcheck source=bashrc.d/listing.sh
source bashrc.d/listing.sh

assert_equal 'TIME_STYLE is exported' '+%Y-%m-%d %H:%M:%S' "$TIME_STYLE"
assert_equal 'll is a function, not an alias' 'function' "$(type -t ll)"

workdir="$TEST_TMP/listing"
mkdir -p "$workdir/a-directory"
: > "$workdir/plain-file"
: > "$workdir/.hidden-file"
printf 'x' > "$workdir/name with spaces.txt"

output=$(cd "$workdir" && ll)
plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')

# --- header ----------------------------------------------------------------

assert_contains 'the header names the permissions' "$plain" 'PERMS'
assert_contains 'the header names the owner' "$plain" 'USER'
assert_contains 'the header names the size' "$plain" 'SIZE'
assert_contains 'the header names the timestamp' "$plain" 'MODIFIED'
assert_contains 'the header names the file' "$plain" 'NAME'

# The localised ls summary line must not survive.
assert_not_contains 'the English summary line is dropped' "$plain" 'total '
assert_not_contains 'the German summary line is dropped' "$plain" 'insgesamt '

# --- entries ---------------------------------------------------------------

assert_contains 'plain files are listed' "$plain" 'plain-file'
assert_contains 'directories are listed' "$plain" 'a-directory'
assert_contains 'hidden files are listed' "$plain" '.hidden-file'
assert_contains 'names with spaces stay intact' "$plain" 'name with spaces.txt'

# -oa drops the group column, so a listed line has no group between owner and
# size. Checked through the column count of a known entry.
line=$(printf '%s\n' "$plain" | grep -- 'plain-file')
assert_match 'timestamp in the configured format' "$line" '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'

# --- options are passed through -------------------------------------------

output=$(cd "$workdir" && ll -r)
plain_reverse=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains 'ls options reach ls' "$plain_reverse" 'plain-file'

output=$(cd "$TEST_TMP" && ll listing)
plain_arg=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains 'a path argument works' "$plain_arg" 'plain-file'

assert_status 'll returns the underlying ls failure status' 2 \
    ll "$workdir/does-not-exist"

# --- colour ----------------------------------------------------------------

assert_contains 'the output is colourised' "$output" $'\e['

pass 'header, entries, option pass-through, colour, and ls exit status'
