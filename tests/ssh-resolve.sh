#!/usr/bin/env bash

# Regression test for bashrc.d/lib/ssh-resolve-ips.sh and
# bashrc.d/lib/ssh-resolve-hosts.sh.
#
# The IP predicates are pure functions and are tested directly. The commands
# themselves are only exercised on paths that return before any DNS lookup, so
# the test stays offline.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='ssh-resolve'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

# shellcheck source=bashrc.d/ssh-tools.sh
source bashrc.d/ssh-tools.sh

# --- IPv4 ------------------------------------------------------------------

for ip in 10.0.0.1 192.168.178.42 255.255.255.255 0.0.0.0 8.8.8.8; do
    assert "IPv4 accepted: $ip" __ssh_resolve_is_ipv4 "$ip"
done

for ip in 256.0.0.1 10.0.0 10.0.0.1.2 '10.0.0.a' '' 1e2.0.0.1 '10.0.0.1 '; do
    assert_status "IPv4 rejected: '$ip'" 1 __ssh_resolve_is_ipv4 "$ip"
done

# --- IPv6 ------------------------------------------------------------------

for ip in ::1 2001:db8::1 fe80::1 2001:0db8:0000:0000:0000:0000:0000:0001; do
    assert "IPv6 accepted: $ip" __ssh_resolve_is_ipv6 "$ip"
done

for ip in 'nocolon' '' 'example.com' '10.0.0.1'; do
    assert_status "IPv6 rejected: '$ip'" 1 __ssh_resolve_is_ipv6 "$ip"
done

# --- the combined predicate ------------------------------------------------

assert 'the combined predicate takes IPv4' __ssh_resolve_is_ip 10.0.0.1
assert 'the combined predicate takes IPv6' __ssh_resolve_is_ip 2001:db8::1
assert_status 'the combined predicate rejects a name' 1 __ssh_resolve_is_ip web01.example.com

# --- ssh-resolve-ips option handling --------------------------------------

assert_status '--help succeeds' 0 ssh_resolve_ips --help
help_output=$(ssh_resolve_ips --help)
assert_contains 'help names the timeout variable' "$help_output" 'SSH_RESOLVE_IP_TIMEOUT'

assert_status 'more than one argument' 2 ssh_resolve_ips one two
assert_status 'a zero timeout' 2 env SSH_RESOLVE_IP_TIMEOUT=0 bash -c \
    'source bashrc.d/ssh-tools.sh; ssh_resolve_ips filter'
assert_status 'a non-numeric timeout' 2 env SSH_RESOLVE_IP_TIMEOUT=abc bash -c \
    'source bashrc.d/ssh-tools.sh; ssh_resolve_ips filter'

# --- ssh-resolve-hosts option handling ------------------------------------

assert_status '--help succeeds' 0 ssh_resolve_hosts --help
help_output=$(ssh_resolve_hosts --help)
assert_contains 'help names its own timeout variable' "$help_output" 'SSH_RESOLVE_HOST_TIMEOUT'
assert_contains 'help points at the counterpart' "$help_output" 'ssh-resolve-ips'

assert_status 'more than one argument' 2 ssh_resolve_hosts one two
assert_status 'a zero timeout' 2 env SSH_RESOLVE_HOST_TIMEOUT=0 bash -c \
    'source bashrc.d/ssh-tools.sh; ssh_resolve_hosts filter'

# --- load order dependency -------------------------------------------------

# Both commands are thin wrappers around lib/ssh-resolve.sh and have to say so
# instead of failing obscurely when it has not been loaded.
# The guard fires at source time, so both streams are captured here.
for command_name in ssh_resolve_hosts ssh_resolve_ips; do
    load_order=$(bash -c '
        source bashrc.d/lib/ssh-config.sh
        source "bashrc.d/lib/${1//_/-}.sh"
        "$1"
    ' _ "$command_name" 2>&1)
    assert_contains "the missing library is named for $command_name" \
        "$load_order" 'ssh-resolve.sh'
done

# The shared table is what both of them call.
assert_equal 'the shared table exists' 'function' "$(type -t __ssh_resolve_table)"

# --- caches ----------------------------------------------------------------

assert_equal 'the IP cache can be invalidated' 'function' \
    "$(type -t __ssh_resolve_ips_cache_invalidate)"
assert_equal 'the host cache can be invalidated' 'function' \
    "$(type -t __ssh_resolve_hosts_cache_invalidate)"
assert_status 'invalidating the IP cache works' 0 __ssh_resolve_ips_cache_invalidate
assert_status 'invalidating the host cache works' 0 __ssh_resolve_hosts_cache_invalidate

pass 'IPv4/IPv6 predicates, help, argument and timeout validation, load order'
