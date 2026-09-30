#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for bashrc.d/prompt-local.sh: the status segment that
# bash-git-prompt calls, its ordering (duration, last command, exit code) and
# the repetition knobs.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='prompt-local'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config_root=$PWD
test_sandbox

# bashrc.sh exports this before sourcing the module; the test provides it so
# GIT_PROMPT_THEME_FILE still points at the versioned theme.
BASH_CONFIG_ROOT=$config_root

# A non-interactive shell has neither of these, and the test runs with "set -u".
PROMPT_COMMAND=${PROMPT_COMMAND-}
PS1=${PS1-}

# bash-git-prompt defines these; the module is tested without it, so the test
# provides recognisable stand-ins.
Red='<red>'
Green='<green>'
BoldBlue='<blue>'
ResetColor='<reset>'

# shellcheck source=bashrc.d/prompt-core.sh
source bashrc.d/prompt-core.sh
# shellcheck source=bashrc.d/prompt-local.sh
source bashrc.d/prompt-local.sh

assert_equal 'the repetition is on by default' 1 "$PROMPT_LOCAL_SHOW_COMMAND"

# These are upstream bash-git-prompt switches, not booleans with local
# semantics. Keep their exact values covered because reversing them re-enables
# the expensive work this backend is specifically configured to avoid.
assert_equal 'remote fetches are disabled' 0 "$GIT_PROMPT_FETCH_REMOTE_STATUS"
assert_equal 'untracked-file scanning is disabled' no "$GIT_PROMPT_SHOW_UNTRACKED_FILES"
assert_equal 'submodule scanning is disabled' 1 "$GIT_PROMPT_IGNORE_SUBMODULES"
assert_equal 'changed-file counting is disabled' 0 "$GIT_PROMPT_SHOW_CHANGED_FILES_COUNT"

# --- a fast, successful command -------------------------------------------

__cmd_last_exit=0
__cmd_duration='12ms'
__cmd_elapsed_us=12000
__cmd_last_command='ls'

output=$(prompt_callback)
assert_not_contains 'a fast command hides its duration' "$output" '12ms'
assert_contains 'the command is still repeated' "$output" 'ls'

# --- a slow, successful command -------------------------------------------

__cmd_duration='1.500s'
__cmd_elapsed_us=1500000
__cmd_last_command='mvn clean verify'

output=$(prompt_callback)
assert_contains 'the duration is shown in green' "$output" '<green>1.500s'
assert_contains 'the command is repeated' "$output" 'mvn clean verify'
assert_not_contains 'no error marker on success' "$output" '✗'

# --- a failure -------------------------------------------------------------

__cmd_last_exit=42
__cmd_duration='2m07s'
__cmd_elapsed_us=127000000
__cmd_last_command='git push --force-with-lease'

output=$(prompt_callback)
before=${output%%git push*}
after=${output#*git push --force-with-lease}
assert_contains 'the duration comes before the command' "$before" '2m07s'
assert_contains 'the exit code comes after the command' "$after" '42'
assert_contains 'the exit code is red' "$after" '<red>✗ 42'

# --- untrusted text --------------------------------------------------------

__cmd_last_command='echo $(id) `hostname`'
output=$(prompt_callback)
assert_contains 'command substitution is neutralised' "$output" '\$(id)'
assert_not_contains 'no live backtick survives' "$output" ' `hostname`'

# --- knobs -----------------------------------------------------------------

__cmd_last_command='0123456789abcdef'
PROMPT_LOCAL_COMMAND_MAX_LEN=10
output=$(prompt_callback)
assert_contains 'a long command keeps its head' "$output" '012345678'
assert_not_contains 'a long command drops its tail' "$output" 'abcdef'
PROMPT_LOCAL_COMMAND_MAX_LEN=60

PROMPT_LOCAL_SHOW_COMMAND=0
__cmd_last_command='ls -la'
output=$(prompt_callback)
assert_not_contains 'the repetition can be switched off' "$output" 'ls -la'
assert_contains 'the exit code survives' "$output" '42'
PROMPT_LOCAL_SHOW_COMMAND=1

pass 'status ordering, command repetition, quoting and the repetition knobs'
