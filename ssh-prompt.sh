#!/usr/bin/env bash

# Synchronisiert prompt.sh, installiert einen Loader in der entfernten .bashrc
# und startet danach eine normale SSH-Sitzung (keine zusaetzliche Login-Bash).
sshp() (
    if (( $# != 1 )) || [[ -z ${1-} || ${1-} == -* ]]; then
        printf 'Aufruf: sshp user@host oder sshp SSH-Config-Alias\n' >&2
        return 2
    fi

    local target=$1
    local prompt_file="$HOME/.config/bash/ssh-prompt/prompt.sh"
    local archive remote_script

    [[ -r $prompt_file ]] || {
        printf 'sshp: %s fehlt oder ist nicht lesbar.\n' "$prompt_file" >&2
        return 1
    }

    bash -n "$prompt_file" || {
        printf 'sshp: prompt.sh enthaelt einen Syntaxfehler.\n' >&2
        return 1
    }

    archive=$(mktemp -t sshp-prompt.XXXXXX.tgz) || return 1
    trap 'rm -f -- "$archive"' EXIT

    tar -czf "$archive" \
        -C "$HOME/.config/bash/ssh-prompt" prompt.sh || return 1

    # Dieses Skript wird von der regulaeren Remote-Shell ausgefuehrt.
    # tar liest das Archiv von stdin; danach wird die .bashrc atomar angepasst.
    read -r -d '' remote_script <<'REMOTE' || true
set -eu

for command_name in tar bash grep mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf "sshp: %s fehlt auf dem Ziel.\n" "$command_name" >&2
        exit 1
    }
done

umask 077
prompt_dir="$HOME/.cache/ssh-prompt"
prompt_file="$prompt_dir/prompt.sh"
bashrc="$HOME/.bashrc"
backup="$HOME/.bashrc.before-sshp"
start_marker="# >>> sshp managed prompt >>>"

mkdir -p "$prompt_dir"
tar --no-same-owner -xzf - -C "$prompt_dir"
bash -n "$prompt_file"

# Den Loader nur beim ersten Aufruf einfuegen.
if ! { test -f "$bashrc" && grep -Fqx "$start_marker" "$bashrc"; }; then
    if test -f "$bashrc" && ! test -e "$backup"; then
        cp -p "$bashrc" "$backup"
    fi

    temporary=$(mktemp "$HOME/.bashrc.sshp.XXXXXX")
    trap 'rm -f -- "$temporary"' EXIT HUP INT TERM

    if test -f "$bashrc"; then
        cat "$bashrc" >"$temporary"
        chmod --reference="$bashrc" "$temporary" 2>/dev/null || chmod 600 "$temporary"
    fi

    cat >>"$temporary" <<'LOADER'

# >>> sshp managed prompt >>>
if [[ -n ${SSH_CONNECTION-} &&
      -r "$HOME/.cache/ssh-prompt/prompt.sh" ]]; then
    source "$HOME/.cache/ssh-prompt/prompt.sh"
fi
# <<< sshp managed prompt <<<
LOADER

    bash -n "$temporary"
    mv -f "$temporary" "$bashrc"
    trap - EXIT HUP INT TERM
fi
REMOTE

    # Verbindung 1: Prompt uebertragen und Loader einrichten.
    if ! command ssh -T -o RemoteCommand=none "$target" "$remote_script" \
        < "$archive"; then
        printf 'sshp: Synchronisierung oder .bashrc-Aktualisierung fehlgeschlagen.\n' >&2
        return 1
    fi

    # Verbindung 2: normale interaktive SSH-Sitzung.
    command ssh "$target"
)
