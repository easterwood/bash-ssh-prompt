#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for prompt.sh: the remote wiring around the shared Gruvbox
# prompt, and the pre-4.2 fallback builder.
#
# Neither had any coverage. The fallback in particular is the path you never
# see locally, because your own shell is Bash 5 -- but a stock macOS bash is
# 3.2, so it is what sshp actually gives you on a Mac. A defect there surfaces
# on someone else's host, mid-task.
#
# prompt.sh guards on [[ $- == *i* ]], so everything here runs in a real
# interactive shell started with --rcfile, the same approach tests/history.sh
# uses. BASH_VERSINFO is readonly and cannot be faked, which is why the builder
# is defined unconditionally in prompt.sh and called directly below.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='remote-prompt'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

config_root=$PWD
rcfile="$TEST_TMP/rcfile"
outfile="$TEST_TMP/out"

# render PRE-SOURCE-LINES POST-SOURCE-LINES [EXPRESSION]
# Starts an interactive shell, sources prompt.sh in it and prints EXPRESSION
# (default: the PS1 the fallback builder produces).
render() {
    local pre=$1 post=$2 expression=${3-'$PS1'}

    : > "$outfile"
    {
        printf '%s\n' "$pre"
        printf 'source %q/prompt.sh\n' "$config_root"
        printf '%s\n' "$post"
        printf 'printf "%%s" "%s" > %q\n' "$expression" "$outfile"
        printf 'exit 0\n'
    } > "$rcfile"

    bash --rcfile "$rcfile" -i < /dev/null > /dev/null 2>&1

    # Without this, a shell that died early would leave an empty file and every
    # assert_not_contains below would pass for the wrong reason. No expression
    # used here is legitimately empty.
    [[ -s $outfile ]] || fail "the interactive shell produced nothing for: $expression"
    cat "$outfile"
}

# The fallback builder, with the timer variables prompt-core.sh would have set.
fallback() {
    render "$1" "$2
__remote_prompt_build"
}

# --- the fallback exists on a modern shell too ------------------------------

kind=$(render '' '' '$(type -t __remote_prompt_build)')
assert_equal 'the fallback builder is always defined' 'function' "$kind"

# --- exit code and duration -------------------------------------------------

ps1=$(fallback '' '__cmd_last_exit=0; __cmd_elapsed_us=1000')
assert_not_contains 'a fast success shows no status' "$ps1" '✗'
assert_not_contains 'and no duration' "$ps1" 'e[32m'

ps1=$(fallback '' '__cmd_last_exit=3; __cmd_duration=1.20s; __cmd_elapsed_us=1200000')
assert_contains 'a failure shows the exit code' "$ps1" '✗ 3'
assert_contains 'in red' "$ps1" 'e[31m'
assert_contains 'with the duration appended' "$ps1" '1.20s'

ps1=$(fallback '' '__cmd_last_exit=0; __cmd_duration=0.50s; __cmd_elapsed_us=500000')
assert_contains 'a slow success shows the duration' "$ps1" '0.50s'
assert_contains 'in green' "$ps1" 'e[32m'
assert_not_contains 'and no exit code' "$ps1" '✗'

# The threshold is 100000 microseconds, the same one prompt-gruvbox.sh uses.
ps1=$(fallback '' '__cmd_last_exit=0; __cmd_duration=0.09s; __cmd_elapsed_us=99999')
assert_not_contains 'just below the threshold stays quiet' "$ps1" '0.09s'
ps1=$(fallback '' '__cmd_last_exit=0; __cmd_duration=0.10s; __cmd_elapsed_us=100000')
assert_contains 'exactly at the threshold shows the duration' "$ps1" '0.10s'

# --- the host marker --------------------------------------------------------

ps1=$(fallback "export SSH_CONNECTION='10.0.0.2 51000 10.0.0.9 22'" '__cmd_last_exit=0')
assert_contains 'an SSH session is marked' "$ps1" '[SSH \h]'

ps1=$(fallback 'unset SSH_CONNECTION' '__cmd_last_exit=0')
assert_not_contains 'a local shell is not' "$ps1" '[SSH'

# --- the repeated command ---------------------------------------------------

ps1=$(fallback '' '__cmd_last_exit=0; __cmd_last_command="make build"')
assert_contains 'the last command is repeated' "$ps1" 'last: make build'

ps1=$(fallback '' '__cmd_last_exit=0; __cmd_last_command="echo \$(id) \`uname\`"')
assert_contains 'command substitutions are escaped in the fallback PS1' "$ps1" '\$(id)'
assert_contains 'backticks are escaped in the fallback PS1' "$ps1" '\`uname\`'

ps1=$(fallback 'export SSH_PROMPT_SHOW_COMMAND=0' \
    '__cmd_last_exit=0; __cmd_last_command="make build"')
assert_not_contains 'SSH_PROMPT_SHOW_COMMAND=0 switches it off' "$ps1" 'last:'

ps1=$(fallback '' '__cmd_last_exit=0; __cmd_last_command=""')
assert_not_contains 'nothing is repeated without a command' "$ps1" 'last:'

# --- the input symbol -------------------------------------------------------

# EUID is readonly, so only the branch matching the current user can be
# exercised. Both are asserted through the same check.
ps1=$(fallback '' '__cmd_last_exit=0')
if (( EUID == 0 )); then
    assert_contains 'root gets the hash symbol' "$ps1" '#'
    assert_contains 'and a red working directory' "$ps1" 'e[31m\]\w'
else
    assert_contains 'a normal user gets the arrow symbol' "$ps1" '❯'
    assert_contains 'and a yellow working directory' "$ps1" 'e[33m\]\w'
fi

assert_contains 'the prompt is three lines' "$ps1" '\n\t '

# --- the remote wiring on a current shell -----------------------------------

# This is what sshp actually installs: the same prompt-gruvbox.sh as locally,
# with the Git segment switched off and the host name added.
git_off=$(render '' '' '$PROMPT_GRUVBOX_GIT')
assert_equal 'the remote prompt drops the Git segment' '0' "$git_off"

show_host=$(render '' '' '$PROMPT_GRUVBOX_SHOW_HOST')
assert_equal 'and shows the host name instead' '1' "$show_host"

wiring=$(render '' '' '${PROMPT_COMMAND[*]}')
assert_contains 'the timer stops first' "$wiring" '__cmd_timer_stop'
assert_contains 'the gruvbox builder runs' "$wiring" '__gb_build'
assert_contains 'the timer is re-armed last' "$wiring" '__cmd_timer_arm'
assert_not_contains 'the fallback builder is not wired in' "$wiring" '__remote_prompt_build'

ps1=$(render "export SSH_CONNECTION='10.0.0.2 51000 10.0.0.9 22'" '__gb_build')
assert_contains 'the rendered prompt carries user and host' "$ps1" '\u@\h'
# The Git segment is the only one drawn on aqua, so its background is a
# reliable marker even where the Nerd Font glyph would not survive the file.
assert_not_contains 'and no Git segment' "$ps1" '48;2;104;157;106'

# --- the welcome banner -----------------------------------------------------

banner=$(render "export SSH_CONNECTION='10.0.0.2 51000 10.0.0.9 22'" '' \
    '$SSHP_WELCOME_SHOWN')
assert_equal 'the banner marks itself as shown' '1' "$banner"

pass 'fallback builder, remote wiring without Git, and the welcome guard'
