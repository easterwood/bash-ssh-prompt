#!/usr/bin/env bash

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

pass 'clock, duration formatting across all ranges, exit code, title escaping'
