#!/usr/bin/env bash

# Executes the actual pre-4.2 remote path under an old Bash. The normal suite
# can call the fallback builder on a current shell, but BASH_VERSINFO is
# readonly, so only this CI test proves prompt.sh itself parses and wires the
# legacy branch on Bash 3.2.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." || exit 1

TEST_NAME='legacy-remote-bash'
# shellcheck source=tests/lib.sh
source tests/lib.sh

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))); then
    fail "this integration test requires Bash older than 4.2, got $BASH_VERSION"
fi

config_root=$PWD
test_sandbox
rcfile="$TEST_TMP/rcfile"
outfile="$TEST_TMP/out"

cat > "$rcfile" <<EOF_RC
export SSHP_WELCOME_SHOWN=1
export SSH_CONNECTION='10.0.0.2 51000 10.0.0.9 22'
source '$config_root/prompt.sh'
__cmd_last_exit=7
__cmd_duration=1.25s
__cmd_elapsed_us=1250000
__cmd_last_command='echo \$(id)'
__remote_prompt_build
printf 'builder=%s\n' "\$(type -t __remote_prompt_build)" > '$outfile'
printf 'gruvbox=%s\n' "\$(type -t __gb_build 2>/dev/null || true)" >> '$outfile'
printf 'hooks=%s\n' "\${PROMPT_COMMAND-}" >> '$outfile'
printf 'ps1=%s\n' "\$PS1" >> '$outfile'
exit 0
EOF_RC

bash --noprofile --rcfile "$rcfile" -i < /dev/null >/dev/null 2>&1 ||
    fail 'load prompt.sh in the legacy interactive shell'
[[ -s $outfile ]] || fail 'legacy shell produced no result'
output=$(< "$outfile")

assert_contains 'legacy prompt builder is available' "$output" 'builder=function'
assert_not_contains 'legacy branch does not parse/load Gruvbox' "$output" 'gruvbox=function'
assert_contains 'legacy branch stops the timer first' "$output" 'hooks=__cmd_timer_stop'
assert_contains 'legacy branch wires its own builder' "$output" '__remote_prompt_build'
assert_contains 'legacy branch re-arms the timer' "$output" '__cmd_timer_arm'
assert_contains 'legacy prompt carries the failure status' "$output" '✗ 7'
assert_contains 'legacy prompt keeps command substitution escaped' "$output" 'echo \$(id)'

pass "prompt.sh parses and uses the fallback on Bash $BASH_VERSION"
