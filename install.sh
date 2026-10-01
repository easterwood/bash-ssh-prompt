#!/usr/bin/env bash
set -euo pipefail

config_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
bashrc="$HOME/.bashrc"
timestamp=$(date +%Y%m%d-%H%M%S)
backup="$HOME/.bashrc.before-modular-config.$timestamp"

# Syntax-check every shell file in the checkout rather than a hand-maintained
# list. The list used to miss bashrc.d/lib/*.sh and bashrc.d/completions/*.bash
# entirely, so an error there surfaced only when the next shell started -- and
# it needed editing whenever a module was added. This is the same expression
# the CI syntax job runs, so local and CI now check the same set. The untracked
# local.sh is included on purpose: bashrc.sh sources it, so a syntax error
# there breaks the shell just as surely.
syntax_errors=0
while IFS= read -r file; do
    bash -n "$file" || syntax_errors=1
done < <(find "$config_root" \
    \( -name .git -o -name node_modules \) -prune -o \
    -type f \( -name '*.sh' -o -name '*.bash' \) -print | sort)

if ((syntax_errors)); then
    printf 'Aborted: the checkout contains syntax errors; nothing was changed.\n' >&2
    exit 1
fi

if [[ -e $bashrc ]]; then
    cp -p "$bashrc" "$backup"
    printf 'Backup: %s\n' "$backup"
fi

printf -v quoted_root '%q' "$config_root"
{
    printf '%s\n' '# Generated loader for the versioned Bash configuration.'
    printf 'BASH_CONFIG_ROOT=%s\n' "$quoted_root"
    # The single quotes are the point: $BASH_CONFIG_ROOT has to reach the
    # generated ~/.bashrc unexpanded, so the loader works after a move.
    # shellcheck disable=SC2016
    printf '%s\n' 'source "$BASH_CONFIG_ROOT/bashrc.sh"'
} > "$bashrc"

bash -n "$bashrc"
printf 'Installed. Reload with: source %q\n' "$bashrc"
