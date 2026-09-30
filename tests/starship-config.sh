#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

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

# --- the palette exists twice ----------------------------------------------

# starship.toml carries hex, prompt-gruvbox.sh carries the same colours as RGB
# triples for its own escape sequences. Neither can read the other, so the two
# are compared here instead of drifting apart unnoticed.
declare -A toml_palette=()
while IFS= read -r palette_line; do
    [[ $palette_line =~ ^([a-z0-9_]+)' = '\'\#([0-9a-fA-F]{6})\'$ ]] || continue
    toml_palette[${BASH_REMATCH[1]}]=${BASH_REMATCH[2],,}
done <<< "$(sed -n '/^\[palettes.gruvbox\]/,/^$/p' starship.toml)"

assert_greater 'the toml palette was parsed' "${#toml_palette[@]}" 5

# prompt-gruvbox.sh needs the timer helpers from prompt-core.sh.
# shellcheck source=bashrc.d/prompt-core.sh
source bashrc.d/prompt-core.sh
# shellcheck source=bashrc.d/prompt-gruvbox.sh
source bashrc.d/prompt-gruvbox.sh

assert_equal 'both palettes define the same colour names' \
    "$(printf '%s\n' "${!toml_palette[@]}" | sort | tr '\n' ' ')" \
    "$(printf '%s\n' "${!__gb_rgb[@]}" | sort | tr '\n' ' ')"

for name in $(printf '%s\n' "${!toml_palette[@]}" | sort); do
    IFS=';' read -r red green blue <<< "${__gb_rgb[$name]}"
    printf -v as_hex '%02x%02x%02x' "$red" "$green" "$blue"
    assert_equal "palette '$name' agrees between toml and gruvbox" \
        "${toml_palette[$name]}" "$as_hex"
done

pass 'line layout, and the palette matching bashrc.d/prompt-gruvbox.sh'
