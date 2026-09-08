#!/usr/bin/env bash
set -euo pipefail

config_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
bashrc="$HOME/.bashrc"
timestamp=$(date +%Y%m%d-%H%M%S)
backup="$HOME/.bashrc.before-modular-config.$timestamp"

for file in \
    bashrc.sh prompt.sh ssh-prompt.sh .git-prompt-colors.sh \
    bashrc.d/environment.sh bashrc.d/history.sh bashrc.d/listing.sh \
    bashrc.d/prompt-core.sh bashrc.d/prompt-local.sh; do
    bash -n "$config_root/$file"
done

if [[ -e $bashrc ]]; then
    cp -p "$bashrc" "$backup"
    printf 'Sicherung: %s\n' "$backup"
fi

printf -v quoted_root '%q' "$config_root"
{
    printf '%s\n' '# Generated loader for the versioned Bash configuration.'
    printf 'BASH_CONFIG_ROOT=%s\n' "$quoted_root"
    printf '%s\n' 'source "$BASH_CONFIG_ROOT/bashrc.sh"'
} > "$bashrc"

bash -n "$bashrc"
printf 'Installiert. Neu laden mit: source %q\n' "$bashrc"
