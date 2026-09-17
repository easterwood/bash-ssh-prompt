#!/usr/bin/env bash

# Regression test for bashrc.sh prompt selection through local.sh.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='prompt-selection'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config_root=$PWD
test_sandbox
root="$TEST_TMP/config"
cp -a "$config_root/." "$root/" || fail 'copy config'

mkdir -p "$HOME/.bash-git-prompt"
cat > "$HOME/.bash-git-prompt/gitprompt.sh" <<'STUB'
__TEST_GITPROMPT=1
PS1='git> '
STUB

# starship init bash prints shell code. This test double makes it observable
# without requiring Starship itself in the test environment.
test_stub starship <<'STUB'
#!/usr/bin/env bash
if [[ ${1-} == init && ${2-} == bash ]]; then
    printf '%s\n' '__TEST_STARSHIP=1' "PS1='starship> '"
fi
STUB

run_backend() {
    local backend=$1
    printf 'BASH_PROMPT_BACKEND=%q\n' "$backend" > "$root/local.sh"
    env HOME="$HOME" PATH="$PATH" bash --noprofile --rcfile "$root/bashrc.sh" -i -c \
        'printf "star=%s git=%s gb=%s cfg=%s\n" \
            "${__TEST_STARSHIP-0}" "${__TEST_GITPROMPT-0}" \
            "$(type -t __gb_build 2>/dev/null || true)" "${STARSHIP_CONFIG-}"' \
        2>/dev/null
}

output=$(run_backend starship)
assert_contains 'starship can be selected' "$output" 'star=1 git=0 gb='
assert_contains 'starship uses the versioned config' "$output" "cfg=$root/starship.toml"

output=$(run_backend bash-git-prompt)
assert_contains 'bash-git-prompt can be selected' "$output" 'star=0 git=1 gb='

output=$(run_backend gruvbox)
assert_contains 'gruvbox can be selected' "$output" 'star=0 git=0 gb=function'

output=$(run_backend prompt-local)
assert_contains 'prompt-local is accepted as an alias' "$output" 'star=0 git=1 gb='

output=$(run_backend prompt-gruvbox.sh)
assert_contains 'prompt-gruvbox.sh is accepted as an alias' "$output" 'star=0 git=0 gb=function'

output=$(run_backend auto)
assert_contains 'auto prefers starship when present' "$output" 'star=1 git=0 gb='

# Remove the Starship test double: explicit starship must degrade to Gruvbox.
rm -f "$TEST_STUB_DIR/starship"
output=$(run_backend starship)
assert_contains 'missing starship falls back to gruvbox' "$output" 'star=0 git=0 gb=function'

# Remove bash-git-prompt too: its explicit backend has the same safe fallback.
rm -f "$HOME/.bash-git-prompt/gitprompt.sh"
output=$(run_backend bash-git-prompt)
assert_contains 'missing bash-git-prompt falls back to gruvbox' "$output" 'star=0 git=0 gb=function'

pass 'local.sh selects Starship, bash-git-prompt or Gruvbox'
