#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for bashrc.d/commands.sh (bash-commands), the overview and
# its self-check.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='bash-commands'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config_root=$PWD
test_sandbox

# The full configuration is loaded, otherwise --check would rightly complain
# about ll and sshp.
# shellcheck source=bashrc.d/listing.sh
source "$config_root/bashrc.d/listing.sh"
# shellcheck source=bashrc.d/ssh-tools.sh
source "$config_root/bashrc.d/ssh-tools.sh"
# shellcheck source=ssh-prompt.sh
source "$config_root/ssh-prompt.sh"

strip_colour() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# --- the listing -----------------------------------------------------------

listing=$(bash_config_commands | strip_colour)
assert_contains 'the listing groups by purpose' "$listing" 'SSH overview'
assert_contains 'll is listed' "$listing" 'll'
assert_contains 'sshp is listed' "$listing" 'sshp'
assert_contains 'known-hosts is listed' "$listing" 'known-hosts'
assert_contains 'the merged option is mentioned' "$listing" '--clean'
assert_not_contains 'the removed command is gone' "$listing" 'known-hosts-clean '

details=$(bash_config_commands --details | strip_colour)
assert_contains 'details show the defining file' "$details" 'bashrc.d/lib/known-hosts.sh'
assert_contains 'details show the synonym' "$details" 'ssh-known-hosts'

# --- the self-check --------------------------------------------------------

assert_status 'every listed command exists' 0 bash_config_commands --check
check_output=$(bash_config_commands --check | strip_colour)
assert_contains 'the check reports the kind' "$check_output" 'Alias'
assert_not_contains 'nothing is missing' "$check_output" 'missing'

# A stale row has to be caught. The table is rebuilt in a subshell so the real
# one stays untouched.
stale=$(
    bash_config_commands() { :; }
    unalias known-hosts 2>/dev/null
    unset -f ssh_known_hosts
    source "$config_root/bashrc.d/commands.sh"
    bash_config_commands --check >/dev/null 2>&1
    printf '%d\n' "$?"
)
assert_equal 'a missing command fails the check' 1 "$stale"

# --- filtering -------------------------------------------------------------

filtered=$(bash_config_commands known | strip_colour)
assert_contains 'the filter keeps matching rows' "$filtered" 'known-hosts'
assert_not_contains 'the filter drops other rows' "$filtered" 'Directory listing'

filtered=$(bash_config_commands KNOWN | strip_colour)
assert_contains 'the filter ignores case' "$filtered" 'known-hosts'

filtered=$(bash_config_commands 'reverse-dns' | strip_colour)
assert_contains 'the description is searched too' "$filtered" 'ssh-resolve-ips'

empty=$(bash_config_commands no-such-command | strip_colour)
assert_status 'an empty filter result is not an error' 0 bash_config_commands no-such-command
assert_contains 'an empty result is reported' "$empty" 'no-such-command'

# --- rejected input --------------------------------------------------------

assert_status '--check with a filter' 2 bash_config_commands --check known
assert_status '--check with --details' 2 bash_config_commands --check --details
assert_status 'two filters' 2 bash_config_commands one two
assert_status 'an unknown option' 2 bash_config_commands --nope
assert_status '--help succeeds' 0 bash_config_commands --help

# --- completion ------------------------------------------------------------

COMP_WORDS=(bash-commands kno)
COMP_CWORD=1
_bash_commands_completion
assert_contains 'command names are completed' " ${COMPREPLY[*]} " ' known-hosts '
assert_not_contains 'the removed name is not completed' " ${COMPREPLY[*]} " 'known-hosts-clean'

COMP_WORDS=(bash-commands --check '')
COMP_CWORD=2
_bash_commands_completion
assert_equal 'nothing is completed after --check' 0 "${#COMPREPLY[@]}"

pass 'listing, details, self-check, filter, rejected combinations, completion'
