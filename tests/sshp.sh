#!/usr/bin/env bash

# Regression test for ssh-prompt.sh: the argument parser of sshp and the
# guards around it. No connection is made; the parser is exercised directly
# and the full function only through cases that fail before any ssh call.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='sshp'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config_root=$PWD
test_sandbox

# shellcheck source=ssh-prompt.sh
source "$config_root/ssh-prompt.sh"

# --- destination and options ----------------------------------------------

assert 'a plain destination parses' __sshp_parse_args user@host
assert_equal 'destination recognised' 'user@host' "$__sshp_target"
assert_equal 'no remote command' 0 "${#__sshp_extra[@]}"
assert_contains 'WarnWeakCrypto is set first' "${__sshp_options[*]}" 'WarnWeakCrypto=no'

assert 'options before the destination' __sshp_parse_args -v -p 2222 host
assert_equal 'the destination is still found' 'host' "$__sshp_target"
assert_contains 'the flag is passed through' "${__sshp_options[*]}" '-v'
assert_contains 'the option argument stays attached' "${__sshp_options[*]}" '-p 2222'

assert 'an attached option argument' __sshp_parse_args -p2222 host
assert_equal 'attached form parses too' 'host' "$__sshp_target"

assert '--force is consumed' __sshp_parse_args --force host
assert_equal '--force sets the flag' 1 "$__sshp_force"
assert_equal '--force is not passed to ssh' '' "$(printf '%s\n' "${__sshp_options[@]}" | grep -x -- --force || true)"

assert 'double dash ends the options' __sshp_parse_args -v -- host
assert_equal 'the destination after -- is used' 'host' "$__sshp_target"
assert_contains 'options before -- are kept' "${__sshp_options[*]}" '-v'
# The destination check runs after --, so a destination starting with "-" is
# still rejected. Documented here so a change in that rule is noticed.
assert_status 'a dash destination is rejected even after --' 2 __sshp_parse_args -- -weird-host

assert 'a remote command is collected' __sshp_parse_args host uname -a
assert_equal 'first word after the destination' 'uname' "${__sshp_extra[0]}"

assert '--help is recognised' __sshp_parse_args --help
assert_equal '--help sets the flag' 1 "$__sshp_help_requested"

# --- rejected input --------------------------------------------------------

assert_status 'no arguments at all' 2 __sshp_parse_args
assert_status 'only an option' 2 __sshp_parse_args -v
assert_status 'a missing option argument' 2 __sshp_parse_args -p

# --- the function itself ---------------------------------------------------

assert_status 'sshp without a destination' 2 sshp
assert_status 'sshp with a remote command' 2 sshp host uname -a

remote_command_error=$(sshp host uname -a 2>&1)
assert_contains 'the error points at plain ssh' "$remote_command_error" 'Use "ssh host uname ..."'

assert_status 'sshp --help succeeds' 0 sshp --help
help_output=$(sshp --help 2>&1)
assert_contains 'help shows the usage line' "$help_output" 'Usage: sshp'
assert_contains 'help mentions --force' "$help_output" '--force'

# A missing sync file has to be caught before anything is copied.
missing_root="$TEST_TMP/empty-root"
mkdir -p "$missing_root"
missing_error=$(BASH_CONFIG_ROOT=$missing_root sshp host 2>&1)
assert_status 'a missing sync file aborts' 1 env BASH_CONFIG_ROOT="$missing_root" bash -c \
    "source '$config_root/ssh-prompt.sh'; sshp host"
assert_contains 'the missing file is named' "$missing_error" 'prompt.sh is missing'

# --- ssh is deliberately left alone ---------------------------------------

assert_equal 'ssh is not redefined as a function' '' "$(type -t ssh | grep -x function || true)"
assert_status 'no ssh alias is installed' 1 alias ssh

pass 'option/destination split, --force, --, remote command rejection, missing sync files'
