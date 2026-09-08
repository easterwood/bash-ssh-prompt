#!/usr/bin/env bash

# Synchronisiert prompt.sh, installiert einen Loader in der entfernten .bashrc
# und startet danach eine normale SSH-Sitzung (keine zusaetzliche Login-Bash).
sshp() (
    local force=0
    if [[ ${1-} == --force ]]; then
        force=1
        shift
    fi

    if (( $# != 1 )) || [[ -z ${1-} || ${1-} == -* ]]; then
        printf 'Aufruf: sshp [--force] user@host oder SSH-Config-Alias\n' >&2
        return 2
    fi

    local target=$1
    local prompt_file="$HOME/.config/bash/ssh-prompt/prompt.sh"
    local state_dir="$HOME/.cache/sshp"
    local archive remote_script signature saved_signature
    local target_crc target_size state_file temporary_state

    [[ -r $prompt_file ]] || {
        printf 'sshp: %s fehlt oder ist nicht lesbar.\n' "$prompt_file" >&2
        return 1
    }

    bash -n "$prompt_file" || {
        printf 'sshp: prompt.sh enthaelt einen Syntaxfehler.\n' >&2
        return 1
    }

    command -v cksum >/dev/null 2>&1 || {
        printf 'sshp: cksum fehlt auf dem lokalen System.\n' >&2
        return 1
    }

    # Der Formatwert erzwingt bei kuenftigen Aenderungen am Remote-Loader
    # einmalig eine erneute Installation.
    signature=$(
        {
            printf '%s\n' 'sshp-sync-format=3'
            cksum "$prompt_file"
        } | cksum
    ) || return 1

    read -r target_crc target_size <<EOF
$(printf '%s' "$target" | cksum)
EOF
    state_file="$state_dir/${target_crc}_${target_size}.state"

    if [[ -r $state_file ]]; then
        IFS= read -r saved_signature < "$state_file"
    else
        saved_signature=''
    fi

    # Keine lokale Aenderung: Die erste Verbindung ist direkt die Sitzung.
    if (( ! force )) && [[ $saved_signature == "$signature" ]]; then
        command ssh -o WarnWeakCrypto=no "$target"
        return
    fi

    archive=$(mktemp -t sshp-prompt.XXXXXX.tgz) || return 1
    trap 'rm -f -- "$archive"' EXIT

    tar -czf "$archive" \
        -C "$HOME/.config/bash/ssh-prompt" prompt.sh || return 1

    # Dieses Skript wird von der regulaeren Remote-Shell ausgefuehrt.
    # tar liest das Archiv von stdin; danach wird die .bashrc atomar angepasst.
    read -r -d '' remote_script <<'REMOTE' || true
set -eu

for command_name in tar bash grep mktemp touch; do
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

# Unterdrueckt MOTD-/Insights-Hinweise und "Last login" fuer diesen Benutzer.
touch "$HOME/.hushlogin"

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
    if ! command ssh -T -o RemoteCommand=none -o WarnWeakCrypto=no \
        "$target" "$remote_script" \
        < "$archive"; then
        printf 'sshp: Synchronisierung oder .bashrc-Aktualisierung fehlgeschlagen.\n' >&2
        return 1
    fi

    # Den neuen Stand erst nach einer vollstaendig erfolgreichen
    # Synchronisierung vermerken.
    mkdir -p "$state_dir" || return 1
    temporary_state=$(mktemp "$state_dir/.state.XXXXXX") || return 1
    printf '%s\n' "$signature" > "$temporary_state" || return 1
    mv -f "$temporary_state" "$state_file" || return 1

    # Verbindung 2: normale interaktive SSH-Sitzung.
    command ssh -o WarnWeakCrypto=no "$target"
)

# Ein einfacher interaktiver SSH-Aufruf verwendet automatisch sshp.
# Optionen und Remote-Befehle werden unveraendert an OpenSSH weitergegeben.
ssh() {
    if (( $# == 1 )) && [[ -n ${1-} && ${1-} != -* ]]; then
        sshp "$1"
    else
        command ssh "$@"
    fi
}
