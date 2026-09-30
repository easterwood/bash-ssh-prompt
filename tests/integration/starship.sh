#!/usr/bin/env bash

# Compatibility test against a real Starship binary. This stays outside
# tests/*.sh because the regular suite is deliberately self-contained and does
# not install external prompt engines.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." || exit 1

TEST_NAME='starship-upstream'
# shellcheck source=tests/lib.sh
source tests/lib.sh

starship_bin=${1-}
expected_version=${2-}
[[ -n $starship_bin && -x $starship_bin ]] ||
    fail 'usage: tests/integration/starship.sh STARSHIP_BIN [EXPECTED_VERSION]'
starship_bin=$(cd -- "$(dirname -- "$starship_bin")" && pwd -P)/$(basename -- "$starship_bin")

version=$("$starship_bin" --version 2>/dev/null | head -n 1) || fail 'run starship --version'
[[ -z $expected_version ]] ||
    assert_contains 'the pinned Starship version is installed' "$version" "$expected_version"

config_root=$PWD
test_sandbox
root="$TEST_TMP/config"
cp -a "$config_root/." "$root/" || fail 'copy config'

# Put the explicitly supplied binary ahead of anything from the runner image.
starship_dir=${starship_bin%/*}
PATH="$TEST_STUB_DIR:$starship_dir:$PATH"
export PATH
: "${TERM:=xterm}"
export TERM

cat > "$root/local.sh" <<'EOF_LOCAL'
BASH_PROMPT_BACKEND=starship
HISTORY_DEDUPE_ON_START=0
EOF_LOCAL

# First exercise the versioned TOML directly. This catches Starship parser or
# module-schema changes even if shell initialization itself still succeeds.
rendered=$(cd -- "$TEST_TMP" && STARSHIP_CONFIG="$root/starship.toml" \
    "$starship_bin" prompt 2>/dev/null) || fail 'render prompt with versioned starship.toml'
assert 'real Starship renders the versioned configuration' test -n "$rendered"

# Then load the complete bashrc with the real `starship init bash` output. The
# pinned Starship preserves pre-existing PROMPT_COMMAND content in
# STARSHIP_PROMPT_COMMAND; history.sh must therefore survive initialization.
output=$(env HOME="$HOME" PATH="$PATH" bash --noprofile --rcfile "$root/bashrc.sh" -i -c '
    printf "precmd=%s\n" "$(type -t starship_precmd 2>/dev/null || true)"
    printf "gruvbox=%s\n" "$(type -t __gb_build 2>/dev/null || true)"
    printf "config=%s\n" "${STARSHIP_CONFIG-}"
    printf "hooks=%s\n" "${PROMPT_COMMAND[*]-${PROMPT_COMMAND-}}"
    printf "preserved=%s\n" "${STARSHIP_PROMPT_COMMAND-}"
' 2>/dev/null) || fail 'load bashrc with real Starship'

assert_contains 'real Starship installs its precmd function' "$output" 'precmd=function'
assert_not_contains 'Starship backend does not load Gruvbox' "$output" 'gruvbox=function'
assert_contains 'bashrc points Starship at the versioned config' \
    "$output" "config=$root/starship.toml"
assert_contains 'Starship owns PROMPT_COMMAND after initialization' \
    "$output" 'hooks=starship_precmd'
assert_contains 'Starship preserves the history hook it replaced' \
    "$output" 'preserved=__history_append'

pass 'real Starship parses the config and composes with the complete bashrc'
