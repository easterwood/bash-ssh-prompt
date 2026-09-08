#!/usr/bin/env bash
# Lokal in Git Bash ausfuehren: bash install.sh
# Sichert zu ersetzende Dateien und .bashrc vor Aenderungen.
set -euo pipefail

if (( $# != 0 )); then
    printf 'Aufruf: bash install.sh\n' >&2
    exit 2
fi

src=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dest="$HOME/.config/bash/ssh-prompt"
stamp=$(date +%Y%m%d-%H%M%S)-$$
backup="$dest/backups/$stamp"
rcfile="$HOME/.bashrc"
load='[[ ! -r "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh" ]] || source "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh"'

for file in prompt.sh ssh-prompt.sh bashrc.snippet.sh; do
    [[ -r "$src/$file" ]] || {
        printf 'Installation: Datei fehlt: %s\n' "$src/$file" >&2
        exit 1
    }
    bash -n "$src/$file"
done

mkdir -p "$dest"
for file in prompt.sh ssh-prompt.sh bashrc.snippet.sh; do
    if [[ -e "$dest/$file" || -L "$dest/$file" ]]; then
        [[ -f "$dest/$file" ]] || {
            printf 'Installation: Ziel ist keine regulaere Datei: %s\n' "$dest/$file" >&2
            exit 1
        }
        if cmp -s -- "$src/$file" "$dest/$file"; then
            continue
        fi
        mkdir -p "$backup"
        cp -L -- "$dest/$file" "$backup/$file"
        # Einen bestehenden Symlink nicht durchschreiben.
        rm -- "$dest/$file"
    fi
    cp -- "$src/$file" "$dest/$file"
done

if [[ -e "$rcfile" && ! -f "$rcfile" ]]; then
    printf 'Installation: ~/.bashrc ist keine regulaere Datei.\n' >&2
    exit 1
fi

if ! grep -Fqx -- "$load" "$rcfile" 2>/dev/null; then
    if [[ -e "$rcfile" ]]; then
        cp -L -- "$rcfile" "$rcfile.ssh-prompt-backup-$stamp"
    fi
    printf '\n# SSH-Prompt-Synchronisierung; lokaler Prompt bleibt unveraendert.\n%s\n' \
        "$load" >> "$rcfile"
fi

printf 'Installiert: %s\n' "$dest"
if [[ -d "$backup" ]]; then
    printf 'Sicherungen ersetzter Dateien: %s\n' "$backup"
fi
printf '\nIn der aktuellen Git Bash laden:\n'
printf 'source "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh"\n\n'
printf 'Danach verbinden:\nsshp alex@server\n'
