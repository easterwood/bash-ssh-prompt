#!/usr/bin/env bash

# Regression tests for the helper-free Starship Powerline configuration.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='starship-config'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config=$(< starship.toml) || fail 'starship.toml is not readable'

assert_not_contains 'Starship config no longer references the helper' \
    "$config" 'starship-line2.sh'
assert_not_contains 'Starship config has no custom Powerline renderer' \
    "$config" 'custom.powerline_context'
assert 'the old helper script is removed' test ! -e bashrc.d/starship-line2.sh

assert_contains 'line one contains the Git context group' \
    "$config" '([](fg:aqua bg:bg1)$git_branch$git_commit$git_status)'
assert_contains 'line one contains the toolchain context group' \
    "$config" '([](fg:blue_bright bg:bg1)$java$package$nodejs$python)'
assert_contains 'line one contains the Docker context group' \
    "$config" '([](fg:bg3 bg:bg1)$docker_context)'
assert_contains 'line one closes after the optional contexts' \
    "$config" $'$docker_context)\\\n[](fg:bg1)'
assert_contains 'line two starts with a rounded bg1 cap' \
    "$config" $'$line_break\\\n[](fg:bg1)\\\n$time'
assert_contains 'line two contains only time duration and status before its cap' \
    "$config" $'$time\\\n$cmd_duration\\\n$status\\\n[](fg:bg1)'
assert_contains 'directory uses the stable context background with yellow accent' \
    "$config" "format = '[ \$path ](fg:yellow bg:bg1)'"

pass 'pure Starship keeps project context on line one and timing on line two'
