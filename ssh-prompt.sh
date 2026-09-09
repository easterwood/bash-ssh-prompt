#!/usr/bin/env bash

# Gleichnamige Aliase entfernen. Aliase werden vor der Funktionsaufloesung
# expandiert und wuerden die Wrapper unten sonst verdecken.
unalias ssh sshp 2>/dev/null || true

# OpenSSH-Optionen, deren Argument als separates Wort folgen kann. Wird nur
# gebraucht, um Optionen sicher vom Ziel zu trennen.
__sshp_option_takes_arg() {
    case $1 in
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-P|-p|-Q|-R|-S|-W|-w)
            return 0
            ;;
    esac
    return 1
}

__sshp_usage() {
    printf 'Aufruf: sshp [--force] [SSH-OPTIONEN ...] user@host\n'
    printf '        sshp [--force] [SSH-OPTIONEN ...] SSH-Config-Alias\n'
    printf '\n'
    printf '  --force   Prompt-Dateien uebertragen, auch wenn die Signatur passt\n'
    printf '  --help    Diese Hilfe anzeigen\n'
    printf '\n'
    printf 'SSH-Optionen werden unveraendert an OpenSSH durchgereicht und gelten\n'
    printf 'sowohl fuer die Synchronisations- als auch fuer die Login-Verbindung.\n'
    printf 'Ein Remote-Kommando wird nicht unterstuetzt, weil sshp immer eine\n'
    printf 'interaktive Sitzung oeffnet. Dafuer "command ssh" verwenden.\n'
}

sshp() (
    local force=0
    local target='' arg option expect_arg=0
    # Eigene Optionen stehen bewusst vorn: bei -o gewinnt in OpenSSH die erste
    # Angabe, dadurch bleibt WarnWeakCrypto=no auch bei eigenen -o erhalten.
    local -a ssh_options=(-o WarnWeakCrypto=no)

    while (( $# )); do
        arg=$1
        shift

        if (( expect_arg )); then
            ssh_options+=("$arg")
            expect_arg=0
            continue
        fi

        case $arg in
            --force)
                force=1
                continue
                ;;
            --help|-h)
                __sshp_usage
                return 0
                ;;
            --)
                target=${1-}
                (( $# )) && shift
                break
                ;;
            -*)
                ssh_options+=("$arg")
                option=${arg:0:2}
                if __sshp_option_takes_arg "$option" && (( ${#arg} == 2 )); then
                    expect_arg=1
                fi
                continue
                ;;
        esac

        # Das erste Wort, das keine Option ist, ist das Ziel.
        target=$arg
        break
    done

    if (( expect_arg )); then
        printf 'sshp: Zur letzten Option fehlt das Argument.\n' >&2
        __sshp_usage >&2
        return 2
    fi

    if [[ -z $target || $target == -* ]]; then
        printf 'sshp: Es wird genau ein SSH-Ziel benoetigt.\n' >&2
        __sshp_usage >&2
        return 2
    fi

    if (( $# )); then
        printf 'sshp: Ein Remote-Kommando wird nicht unterstuetzt: %s\n' "$1" >&2
        printf 'Dafuer "command ssh %s %s ..." verwenden.\n' "$target" "$1" >&2
        return 2
    fi

    local config_root=${BASH_CONFIG_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}
    local state_dir="$HOME/.cache/sshp"
    local archive remote_script signature saved_signature
    local target_crc target_size state_file temporary_state file
    local -a sync_files=(
        prompt.sh
        bashrc.d/listing.sh
        bashrc.d/prompt-core.sh
    )

    for file in "${sync_files[@]}"; do
        [[ -r "$config_root/$file" ]] || {
            printf 'sshp: %s fehlt oder ist nicht lesbar.\n' "$config_root/$file" >&2
            return 1
        }
        bash -n "$config_root/$file" || return 1
    done

    command -v cksum >/dev/null 2>&1 || {
        printf 'sshp: cksum fehlt auf dem lokalen System.\n' >&2
        return 1
    }

    signature=$(
        {
            printf '%s\n' 'sshp-sync-format=4'
            for file in "${sync_files[@]}"; do
                printf '%s\n' "$file"
                cksum "$config_root/$file"
            done
        } | cksum
    ) || return 1

    read -r target_crc target_size <<EOF
$(printf '%s' "$target" | cksum)
EOF
    state_file="$state_dir/${target_crc}_${target_size}.state"
    [[ ! -r $state_file ]] || IFS= read -r saved_signature < "$state_file"

    if (( ! force )) && [[ ${saved_signature-} == "$signature" ]]; then
        command ssh "${ssh_options[@]}" "$target"
        return
    fi

    archive=$(mktemp -t sshp-prompt.XXXXXX.tgz) || return 1
    trap 'rm -f -- "$archive"' EXIT
    tar -czf "$archive" -C "$config_root" "${sync_files[@]}" || return 1

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
bashrc="$HOME/.bashrc"
backup="$HOME/.bashrc.before-sshp"
start_marker="# >>> sshp managed prompt >>>"

touch "$HOME/.hushlogin"
mkdir -p "$prompt_dir"
tar --no-same-owner -xzf - -C "$prompt_dir"
bash -n "$prompt_dir/prompt.sh"
bash -n "$prompt_dir/bashrc.d/listing.sh"
bash -n "$prompt_dir/bashrc.d/prompt-core.sh"

if ! { test -f "$bashrc" && grep -Fqx "$start_marker" "$bashrc"; }; then
    if test -f "$bashrc" && ! test -e "$backup"; then
        cp -p "$bashrc" "$backup"
    fi
    temporary=$(mktemp "$HOME/.bashrc.sshp.XXXXXX")
    trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
    test ! -f "$bashrc" || cat "$bashrc" >"$temporary"
    cat >>"$temporary" <<'LOADER'

# >>> sshp managed prompt >>>
if [[ -n ${SSH_CONNECTION-} && -r "$HOME/.cache/ssh-prompt/prompt.sh" ]]; then
    source "$HOME/.cache/ssh-prompt/prompt.sh"
fi
# <<< sshp managed prompt <<<
LOADER
    bash -n "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$bashrc"
    trap - EXIT HUP INT TERM
fi
REMOTE

    if ! command ssh -T -o RemoteCommand=none "${ssh_options[@]}" \
        "$target" "$remote_script" < "$archive"; then
        printf 'sshp: Synchronisierung oder .bashrc-Aktualisierung fehlgeschlagen.\n' >&2
        return 1
    fi

    mkdir -p "$state_dir" || return 1
    temporary_state=$(mktemp "$state_dir/.state.XXXXXX") || return 1
    printf '%s\n' "$signature" > "$temporary_state" || return 1
    mv -f "$temporary_state" "$state_file" || return 1
    command ssh "${ssh_options[@]}" "$target"
)

ssh() {
    if (( $# == 1 )) && [[ -n ${1-} && ${1-} != -* ]]; then
        sshp "$1"
    else
        command ssh "$@"
    fi
}
