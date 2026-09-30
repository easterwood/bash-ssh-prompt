#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for install.sh and bashrc.sh: the generated loader, the
# backup, path quoting, the syntax gate, and the guard against non-interactive
# shells.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='install'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config_root=$PWD
test_sandbox

# --- a fresh installation --------------------------------------------------

output=$(cd "$config_root" && bash install.sh 2>&1)
status=$?
assert_equal 'install.sh succeeds' 0 "$status"
assert_contains 'the reload command is printed' "$output" 'Reload with:'

bashrc="$HOME/.bashrc"
assert 'the loader was written' test -f "$bashrc"
assert 'the loader is valid bash' bash -n "$bashrc"
assert_contains 'the loader is marked as generated' "$(< "$bashrc")" 'Generated loader'
assert_contains 'the loader points at the checkout' "$(< "$bashrc")" "$config_root"
assert_contains 'the loader sources bashrc.sh' "$(< "$bashrc")" 'source "$BASH_CONFIG_ROOT/bashrc.sh"'
assert_equal 'the loader is three lines' 3 "$(wc -l < "$bashrc")"

assert_equal 'nothing to back up on a fresh install' '' \
    "$(compgen -G "$HOME/.bashrc.before-modular-config.*" || true)"

# --- backup of an existing file -------------------------------------------

printf '# my own bashrc\nexport MINE=1\n' > "$bashrc"
output=$(cd "$config_root" && bash install.sh 2>&1)
assert_contains 'the backup path is printed' "$output" 'Backup:'

backup=$(compgen -G "$HOME/.bashrc.before-modular-config.*" | head -1)
assert 'a backup was created' test -n "$backup"
assert_contains 'the backup holds the previous content' "$(< "$backup")" 'export MINE=1'
assert_not_contains 'the new loader replaced the old file' "$(< "$bashrc")" 'export MINE=1'

# --- a path with spaces ----------------------------------------------------

spaced_root="$TEST_TMP/dir with spaces/bash config"
mkdir -p "$spaced_root"
cp -r "$config_root/." "$spaced_root/"
(cd "$spaced_root" && bash install.sh >/dev/null 2>&1)
assert_status 'the loader survives spaces in the path' 0 bash -n "$bashrc"
assert_contains 'the path is quoted with %q' "$(< "$bashrc")" 'dir\ with\ spaces'

# --- the syntax gate -------------------------------------------------------

broken_root="$TEST_TMP/broken"
mkdir -p "$broken_root"
cp -r "$config_root/." "$broken_root/"
printf 'if [ then\n' >> "$broken_root/bashrc.d/history.sh"
cp "$bashrc" "$TEST_TMP/bashrc.before-broken"

# install.sh runs under "set -e", so it exits with the status of bash -n (2).
assert_status 'a syntax error aborts the installation' 2 bash -c \
    "cd '$broken_root' && bash install.sh"
assert_file 'a failed installation changes nothing' "$bashrc" "$(< "$TEST_TMP/bashrc.before-broken")"

# --- the loader in a real shell -------------------------------------------

(cd "$config_root" && bash install.sh >/dev/null 2>&1)

# Non-interactive shells have to leave immediately: scp and rsync break
# otherwise.
noninteractive=$(env HOME="$HOME" bash -c 'source "$HOME/.bashrc"; type -t ll; printf "rc=%d\n" $?')
assert_contains 'a non-interactive shell defines nothing' "$noninteractive" 'rc='
assert_not_contains 'll is not defined non-interactively' "$noninteractive" 'function'

interactive=$(printf '%s\n' 'type -t ll sshp known-hosts; echo "root=$BASH_CONFIG_ROOT"' |
    env HOME="$HOME" bash -i 2>/dev/null)
assert_contains 'll is defined interactively' "$interactive" 'function'
assert_contains 'BASH_CONFIG_ROOT is exported' "$interactive" "root=$config_root"

pass 'loader, backup, %q quoting, syntax gate, interactive-only loading'
