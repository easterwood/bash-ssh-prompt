#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for the known_hosts parser behind "known-hosts".
#
# It runs against tests/known_hosts.fixture, which holds synthetic parser data
# and deliberately no valid cryptographic keys. ssh-keygen is replaced by a
# counting stub, so the test also pins down how many processes the rendering
# spawns: none for the list and the filter, exactly one for --fingerprints.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='known-hosts'
# shellcheck source=tests/lib.sh
source tests/lib.sh

fixture="$PWD/tests/known_hosts.fixture"

# A sandbox HOME keeps the real ~/.ssh/config out of the test; otherwise the
# parser would resolve the caller's own aliases with ssh -G.
test_sandbox
SSH_KNOWN_HOSTS_FILE=$fixture

# shellcheck source=bashrc.d/ssh-tools.sh
source bashrc.d/ssh-tools.sh

calls=0
ssh-keygen() {
    calls=$((calls + 1))
    [[ $* == "-l -E sha256 -f $fixture" ]]
}

# --- process count ---------------------------------------------------------

ssh_known_hosts >/dev/null
assert_equal 'default view spawns no ssh-keygen' 0 "$calls"

ssh_known_hosts SERVER >/dev/null
assert_equal 'filtered view spawns no ssh-keygen' 0 "$calls"

assert 'fingerprints run with the expected arguments' ssh_known_hosts --fingerprints
assert_equal 'fingerprints spawn exactly one call' 1 "$calls"

# --- parsing and display ---------------------------------------------------

output=$(ssh_known_hosts SERVER)
assert_contains 'filter matches a plaintext host' "$output" 'server.example.com'
assert_not_contains 'filter excludes the marker entry' "$output" 'cert-authority'

output=$(ssh_known_hosts)
assert_contains 'hashed entries stay opaque' "$output" '[hashed hostname]'
assert_contains 'marker entries are listed' "$output" 'cert-authority'

output=$(ssh_known_hosts --lines)
assert_contains 'the LINE column can be enabled' "$output" 'LINE'

output=$(ssh_known_hosts no-such-host)
assert_contains 'an empty result is reported' "$output" 'No readable entries found'

# --- rejected option combinations ------------------------------------------

assert_status 'fingerprints with a filter' 2 ssh_known_hosts --fingerprints server
assert_status 'fingerprints with --lines' 2 ssh_known_hosts --fingerprints --lines
assert_status 'two filters' 2 ssh_known_hosts one two

pass 'zero processes for list and filter, one for fingerprints, filter and hash display'
