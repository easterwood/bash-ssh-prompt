#!/usr/bin/env bash

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
        command ssh -o WarnWeakCrypto=no "$target"
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

    if ! command ssh -T -o RemoteCommand=none -o WarnWeakCrypto=no \
        "$target" "$remote_script" < "$archive"; then
        printf 'sshp: Synchronisierung oder .bashrc-Aktualisierung fehlgeschlagen.\n' >&2
        return 1
    fi

    mkdir -p "$state_dir" || return 1
    temporary_state=$(mktemp "$state_dir/.state.XXXXXX") || return 1
    printf '%s\n' "$signature" > "$temporary_state" || return 1
    mv -f "$temporary_state" "$state_file" || return 1
    command ssh -o WarnWeakCrypto=no "$target"
)

ssh() {
    if (( $# == 1 )) && [[ -n ${1-} && ${1-} != -* ]]; then
        sshp "$1"
    else
        command ssh "$@"
    fi
}
