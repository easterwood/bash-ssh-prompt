#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for bashrc.d/history.sh: the deduplication of the history
# file and the writing of the history after every command.
#
# The behaviour that matters here only exists in an interactive shell, so the
# end-to-end checks start "bash --rcfile ... -i" in the sandbox instead of
# testing inside this process.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='history'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

config_root=$PWD

# --- history_dedupe as a plain function ------------------------------------

# bashrc.sh sources prompt-core.sh before history.sh because history.sh uses
# its central PROMPT_COMMAND composition helpers. The test mirrors that order.
# shellcheck source=bashrc.d/prompt-core.sh
source bashrc.d/prompt-core.sh
# shellcheck source=bashrc.d/history.sh
source bashrc.d/history.sh

assert_equal 'HISTFILE points into the sandbox' "$HOME/.bash_history" "$HISTFILE"
assert_equal 'erasedups and ignorespace are active' \
    'erasedups:ignorespace' "$HISTCONTROL"
assert_contains 'PROMPT_COMMAND writes the history' "${PROMPT_COMMAND[*]}" '__history_append'

fixture="$TEST_TMP/history.fixture"

# Repeated command: only the most recent occurrence survives, with its own
# timestamp, at the position where it was last used.
printf '#1000\nll\n#1001\ngit push\n#1002\nll\n#1003\necho x\n' > "$fixture"
history_dedupe "$fixture"
assert_file 'duplicate moved to its last position' "$fixture" '#1001
git push
#1002
ll
#1003
echo x'

# Multi-line entries must survive as one record.
printf '#1000\nfor i in 1 2; do\necho $i\ndone\n#1001\nll\n#1002\nfor i in 1 2; do\necho $i\ndone\n' > "$fixture"
history_dedupe "$fixture"
assert_file 'multi-line entry kept intact' "$fixture" '#1001
ll
#1002
for i in 1 2; do
echo $i
done'

# Entries without a "#<epoch>" line, as produced by pasting a script into the
# terminal, are one entry per line and must not be merged.
printf 'll\ngit push\nll\nexit\n' > "$fixture"
history_dedupe "$fixture"
assert_file 'timestamp-less file deduplicated' "$fixture" 'git push
ll
exit'

# A file with nothing to do stays byte-identical.
printf '#1000\nll\n#1001\ngit push\n' > "$fixture"
history_dedupe "$fixture"
assert_file 'file without duplicates unchanged' "$fixture" '#1000
ll
#1001
git push'

# Missing or empty files must not produce an error or leave temporary files.
: > "$fixture"
assert_status 'empty file is a no-op' 0 history_dedupe "$fixture"
assert_status 'missing file is a no-op' 0 history_dedupe "$TEST_TMP/does-not-exist"
assert_equal 'no temporary files left behind' '' "$(compgen -G "$TEST_TMP/history.fixture.*" || true)"

# --- end to end in an interactive shell ------------------------------------

# The shipped default is 0: the live rewrite is the most expensive thing in
# the prompt path, so the file is only cleaned at shell start.
assert_equal 'the live rewrite is off by default' '0' "$HISTORY_DEDUPE_LIVE"

# history.sh refuses to load without prompt-core.sh instead of failing halfway
# through with "command not found".
guard=$(bash -c 'source bashrc.d/history.sh; printf "rc=%d\n" "$?"' 2>&1)
assert_contains 'history.sh names its missing dependency' "$guard" 'prompt-core.sh'
assert_contains 'and refuses to load' "$guard" 'rc=1'

# The checks below exercise the live rewrite itself and therefore switch it on
# explicitly instead of relying on the default.
rcfile="$TEST_TMP/rcfile"
printf 'HISTORY_DEDUPE_LIVE=1\nsource %q/bashrc.d/prompt-core.sh\nsource %q/bashrc.d/history.sh\n' \
    "$config_root" "$config_root" > "$rcfile"

# run_shell HOME-DIRECTORY COMMANDS...
# Feeds the commands to an interactive shell and returns its output.
run_shell() {
    local shell_home=$1
    shift
    printf '%s\n' "$@" | env HOME="$shell_home" bash --rcfile "$rcfile" -i 2>/dev/null
}

session_home="$TEST_TMP/session"
mkdir -p "$session_home"

# The history file has to be current without the shell ever exiting cleanly,
# which is the whole point: a Windows reboot never lets it exit.
run_shell "$session_home" 'echo first' 'echo second' >/dev/null
commands=$(grep -v '^#' "$session_home/.bash_history")
assert_equal 'every command written without a clean exit' 'echo first
echo second' "$commands"
assert 'every entry carries a timestamp' \
    grep -qx '#[0-9][0-9]*' "$session_home/.bash_history"

# A repeated command is removed in place and kept at the end, in the file as
# well, during the session and without restarting a shell.
repeat_home="$TEST_TMP/repeat"
mkdir -p "$repeat_home"
run_shell "$repeat_home" 'll' 'git push' 'll' 'echo x' 'git push' >/dev/null
commands=$(grep -v '^#' "$repeat_home/.bash_history")
assert_equal 'duplicates removed live, order preserved' 'll
echo x
git push' "$commands"

# Repeats typed back to back, and a bare Enter on an empty line, must not
# confuse the duplicate detection.
edge_home="$TEST_TMP/edge"
mkdir -p "$edge_home"
run_shell "$edge_home" 'echo a' 'echo a' '' 'echo a' 'echo b' >/dev/null
commands=$(grep -v '^#' "$edge_home/.bash_history")
assert_equal 'back-to-back repeats collapse' 'echo a
echo b' "$commands"

# A following session starts from the cleaned file and adds nothing twice.
run_shell "$edge_home" 'echo c' 'echo a' >/dev/null
commands=$(grep -v '^#' "$edge_home/.bash_history")
assert_equal 'next session keeps the file clean' 'echo b
echo c
echo a' "$commands"

# With the live rewrite switched off, the file is only cleaned at shell start.
off_home="$TEST_TMP/off"
mkdir -p "$off_home"
printf 'HISTORY_DEDUPE_LIVE=0\nsource %q/bashrc.d/prompt-core.sh\nsource %q/bashrc.d/history.sh\n' \
    "$config_root" "$config_root" > "$TEST_TMP/rcfile-off"
printf '%s\n' 'll' 'git push' 'll' |
    env HOME="$off_home" bash --rcfile "$TEST_TMP/rcfile-off" -i >/dev/null 2>&1
commands=$(grep -v '^#' "$off_home/.bash_history")
assert_equal 'live rewrite can be disabled' 'll
git push
ll' "$commands"

printf '%s\n' 'echo done' |
    env HOME="$off_home" bash --rcfile "$TEST_TMP/rcfile-off" -i >/dev/null 2>&1
commands=$(grep -v '^#' "$off_home/.bash_history")
assert_equal 'disabled rewrite still cleans at shell start' 'git push
ll
echo done' "$commands"

pass 'dedupe of files, timestamps, multi-line entries, live rewrite, HISTORY_DEDUPE_LIVE=0'
