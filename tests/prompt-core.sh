#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for bashrc.d/prompt-core.sh: duration formatting, exit-code
# capture and the window title escaping. The clock is replaced so the results
# are deterministic.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='prompt-core'
# shellcheck source=tests/lib.sh
source tests/lib.sh

# shellcheck source=bashrc.d/prompt-core.sh
source bashrc.d/prompt-core.sh

# --- prompt hook composition -----------------------------------------------

# String form: all prompt modules use the same helpers instead of hand-editing
# PROMPT_COMMAND. Trailing semicolons are normalised while hook order is kept.
unset PROMPT_COMMAND
__prompt_command_append existing_hook
assert_equal 'append creates the string hook list' 'existing_hook' "$PROMPT_COMMAND"

__prompt_command_append second_hook third_hook
assert_equal 'append keeps argument order' \
    'existing_hook;second_hook;third_hook' "$PROMPT_COMMAND"

__prompt_command_prepend first_hook zero_hook
assert_equal 'prepend keeps argument order' \
    'first_hook;zero_hook;existing_hook;second_hook;third_hook' "$PROMPT_COMMAND"

PROMPT_COMMAND='existing_hook;'
__prompt_command_append second_hook
assert_equal 'append normalises a trailing separator' \
    'existing_hook;second_hook' "$PROMPT_COMMAND"

__prompt_command_replace replacement_one replacement_two
assert_equal 'replace discards the previous string hooks' \
    'replacement_one;replacement_two' "$PROMPT_COMMAND"

__prompt_command_replace
assert_equal 'replace can clear a string hook list' '' "$PROMPT_COMMAND"

# Bash 5.1 added array-valued PROMPT_COMMAND. Exercise the same API in that
# representation when the running test shell supports it.
if ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))); then
    PROMPT_COMMAND=(existing_hook)
    __prompt_command_prepend first_hook
    __prompt_command_append second_hook third_hook
    assert_equal 'array hooks keep their element boundaries' \
        'first_hook existing_hook second_hook third_hook' "${PROMPT_COMMAND[*]}"

    __prompt_command_replace replacement_one replacement_two
    assert_equal 'replace preserves the array representation' \
        'replacement_one replacement_two' "${PROMPT_COMMAND[*]}"
    assert '__prompt_command_is_array still sees the replaced array' \
        __prompt_command_is_array
fi

unset PROMPT_COMMAND

# --- the clock -------------------------------------------------------------

__cmd_timer_now_us
assert_match 'the clock returns microseconds' "$REPLY" '^[0-9]{10,}$'

real_now=$REPLY
sleep 0.05
__cmd_timer_now_us
assert_greater 'the clock moves forward' "$REPLY" "$real_now"

# From here on the clock is fixed so the formatting is reproducible.
fake_now_us=0
__cmd_timer_now_us() {
    REPLY=$fake_now_us
}

# duration_for MICROSECONDS -> the formatted duration
duration_for() {
    __cmd_timer_start_us=0
    fake_now_us=$1
    __cmd_duration=''
    __cmd_timer_stop
    printf '%s\n' "$__cmd_duration"
}

assert_equal 'below a millisecond'      '<1ms'        "$(duration_for 999)"
assert_equal 'rounded milliseconds'     '250ms'       "$(duration_for 249500)"
assert_equal 'just under a second'      '1000ms'      "$(duration_for 999500)"
assert_equal 'seconds with milliseconds' '1.500s'     "$(duration_for 1500000)"
assert_equal 'just under a minute'      '59.999s'     "$(duration_for 59999000)"
assert_equal 'minutes and seconds'      '1m05s'       "$(duration_for 65000000)"
assert_equal 'just under an hour'       '59m59s'      "$(duration_for 3599000000)"
assert_equal 'hours, minutes, seconds'  '2h03m04s'    "$(duration_for 7384000000)"

# --- exit code -------------------------------------------------------------

__cmd_timer_start_us=0
fake_now_us=1000
(exit 7)
__cmd_timer_stop
assert_equal 'the exit code is captured' 7 "$__cmd_last_exit"

__cmd_timer_start_us=0
fake_now_us=1000
true
__cmd_timer_stop
assert_equal 'success is captured too' 0 "$__cmd_last_exit"

# Without a start time nothing is measured, and no stale duration is kept.
unset __cmd_timer_start_us
__cmd_duration='stale'
true
__cmd_timer_stop
assert_equal 'no measurement without a start time' 'stale' "$__cmd_duration"

# --- shared prompt text helpers --------------------------------------------

__prompt_quote 'feature/$(id)'
assert_equal 'command substitution is neutralised' 'feature/\$(id)' "$REPLY"

__prompt_quote 'a`b`c'
assert_equal 'backticks are neutralised' 'a\`b\`c' "$REPLY"

__prompt_quote 'back\slash'
assert_equal 'backslashes are doubled' 'back\\slash' "$REPLY"

__cmd_last_command=''
assert_status 'without a command there is nothing to show' 1 __prompt_last_command

__cmd_last_command=$'git commit -m\tfix\nstatus'
assert 'a command is formatted' __prompt_last_command 60
assert_equal 'control characters become spaces' \
    'git commit -m fix status' "$REPLY"

__cmd_last_command='echo $(id)'
__prompt_last_command 60
assert_equal 'the repetition is PS1-safe' 'echo \$(id)' "$REPLY"

# The ellipsis is written as $'\u2026' and therefore depends on the locale, so
# the assertion looks at what is kept and what is dropped instead.
__cmd_last_command='0123456789abcdef'
__prompt_last_command 10
assert_contains 'a long command keeps its head' "$REPLY" '012345678'
assert_not_contains 'a long command drops its tail' "$REPLY" 'abcdef'
unset __cmd_last_command

# --- window title ----------------------------------------------------------

# The title itself is an OSC sequence: ESC ] 0 ; TEXT BEL. Only TEXT may not
# contain control characters, so the payload is unwrapped first.
title=$(__cmd_set_window_title "$(printf 'echo \033[31m\a\r\n\tred')")
payload=${title#*;}
payload=${payload%$'\a'}
assert_not_contains 'escape characters removed' "$payload" $'\e'
assert_not_contains 'bell removed' "$payload" $'\a'
assert_not_contains 'carriage return removed' "$payload" $'\r'
assert_not_contains 'newline replaced' "$payload" $'\n'
assert_not_contains 'tab replaced' "$payload" $'\t'
assert_contains 'the command text survives' "$payload" 'red'

test_sandbox
title=$(cd "$HOME" && __cmd_set_window_title 'ls')
assert_contains 'the home directory shows as ~' "$title" '~'
title=$(cd / && __cmd_set_window_title 'ls')
assert_contains 'the root directory shows as /' "$title" '/'
title=$(cd "$HOME" && mkdir -p deep/dir && cd deep/dir && __cmd_set_window_title 'ls')
assert_contains 'otherwise the basename is shown' "$title" 'dir'

pass 'clock, duration formatting across all ranges, exit code, shared text helpers, title escaping'
