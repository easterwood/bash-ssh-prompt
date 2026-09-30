#!/usr/bin/env bash

# Full bashrc.sh integration test for the three local prompt backends. Unit
# tests cover the modules themselves; this one protects the hooks that only
# exist after the startup files have been composed in their real source order.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='bashrc-integration'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config_root=$PWD
test_sandbox
root="$TEST_TMP/config"
cp -a "$config_root/." "$root/" || fail 'copy config'

# bash-git-prompt is external to this repository. The integration test only
# needs its startup file to exist; backend-specific behaviour has its own unit
# tests.
mkdir -p "$HOME/.bash-git-prompt" || fail 'create bash-git-prompt stub directory'
cat > "$HOME/.bash-git-prompt/gitprompt.sh" <<'STUB'
__TEST_GITPROMPT=1
PS1='git> '
STUB

# Starship emits shell code from "starship init bash". Keep this double small:
# this test is about bashrc.sh composition, not Starship's upstream internals.
test_stub starship <<'STUB'
#!/usr/bin/env bash
if [[ ${1-} == init && ${2-} == bash ]]; then
    printf '%s\n' '__TEST_STARSHIP=1' "PS1='starship> '"
fi
STUB

prompt_command_for() {
    local backend=$1

    printf 'BASH_PROMPT_BACKEND=%q\n' "$backend" > "$root/local.sh"
    env HOME="$HOME" PATH="$PATH" bash --noprofile --rcfile "$root/bashrc.sh" -i -c '
        if __prompt_command_is_array; then
            printf "%s" "${PROMPT_COMMAND[0]-}"
            for hook in "${PROMPT_COMMAND[@]:1}"; do
                printf ";%s" "$hook"
            done
            printf "\n"
        else
            printf "%s\n" "${PROMPT_COMMAND-}"
        fi
    ' 2>/dev/null
}

output=$(prompt_command_for starship)
assert_equal 'Starship keeps the history hook from history.sh' \
    '__history_append' "$output"

output=$(prompt_command_for bash-git-prompt)
assert_equal 'bash-git-prompt composes timer and history hooks' \
    '__cmd_timer_stop;__history_append;__cmd_timer_arm' "$output"

output=$(prompt_command_for gruvbox)
assert_equal 'Gruvbox preserves history between timer stop and prompt build' \
    '__cmd_timer_stop;__history_append;__gb_build;__cmd_timer_arm' "$output"

pass 'all local backends preserve the startup hook composition'
