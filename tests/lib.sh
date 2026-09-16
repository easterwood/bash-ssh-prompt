#!/usr/bin/env bash

# Shared helpers for the test scripts. Source this file, do not run it.
#
# The tests deliberately do not use "set -e". They source the real
# configuration, and several of its functions return non-zero as part of their
# normal control flow (an unreachable host, a rejected option combination), so
# an errexit shell would abort mid-test. Every assertion exits on its own.

TEST_NAME=${TEST_NAME:-${BASH_SOURCE[1]##*/}}
__test_checks=0

fail() {
    printf 'FAIL: %s: %s\n' "$TEST_NAME" "$1" >&2
    exit 1
}

__test_ok() {
    __test_checks=$((__test_checks + 1))
}

# assert DESCRIPTION COMMAND [ARG ...]
assert() {
    local description=$1
    shift
    "$@" || fail "$description"
    __test_ok
}

# assert_equal DESCRIPTION EXPECTED ACTUAL
assert_equal() {
    [[ $2 == "$3" ]] || fail "$1: expected '$2', got '$3'"
    __test_ok
}

# assert_contains DESCRIPTION HAYSTACK NEEDLE
assert_contains() {
    [[ $2 == *"$3"* ]] || fail "$1: '$3' not found in output"
    __test_ok
}

# assert_not_contains DESCRIPTION HAYSTACK NEEDLE
assert_not_contains() {
    [[ $2 != *"$3"* ]] || fail "$1: '$3' unexpectedly present in output"
    __test_ok
}

# assert_match DESCRIPTION VALUE EXTENDED-REGEX
assert_match() {
    [[ $2 =~ $3 ]] || fail "$1: '$2' does not match /$3/"
    __test_ok
}

# assert_greater DESCRIPTION LEFT RIGHT  (numeric: LEFT must be larger)
assert_greater() {
    (( $2 > $3 )) || fail "$1: $2 is not greater than $3"
    __test_ok
}

# assert_status DESCRIPTION EXPECTED COMMAND [ARG ...]
assert_status() {
    local description=$1 expected=$2 status=0
    shift 2
    "$@" >/dev/null 2>&1 || status=$?
    [[ $status == "$expected" ]] ||
        fail "$description: expected exit $expected, got $status"
    __test_ok
}

# assert_file DESCRIPTION PATH EXPECTED-CONTENT
assert_file() {
    local actual
    actual=$(< "$2") || fail "$1: $2 is not readable"
    [[ $actual == "$3" ]] || fail "$1: unexpected content of $2:
--- expected ---
$3
--- actual ---
$actual"
    __test_ok
}

# Throwaway HOME plus a stub directory at the front of PATH. Removed on exit.
test_sandbox() {
    TEST_TMP=$(mktemp -d) || fail 'could not create the temporary directory'
    trap 'rm -rf -- "$TEST_TMP"' EXIT
    TEST_HOME="$TEST_TMP/home"
    TEST_STUB_DIR="$TEST_TMP/bin"
    mkdir -p "$TEST_HOME/.ssh" "$TEST_STUB_DIR" || fail 'could not create the sandbox'
    HOME=$TEST_HOME
    PATH="$TEST_STUB_DIR:$PATH"
    export HOME PATH
}

# test_stub NAME  <<'EOF' ... EOF
# The stubs replace ssh, ssh-keygen and ssh-keyscan, which the configuration
# calls through "command", so a shell function would not be enough.
test_stub() {
    cat > "$TEST_STUB_DIR/$1" || fail "could not write the stub $1"
    chmod +x "$TEST_STUB_DIR/$1" || fail "could not make the stub $1 executable"
}

pass() {
    printf 'PASS: %s (%d checks): %s\n' "$TEST_NAME" "$__test_checks" "${1-}"
}
