#!/usr/bin/env bash

# Remove an alias of the same name. Aliases are expanded before function
# resolution and would otherwise shadow the sshp function below.
#
# "ssh" is deliberately left alone: this file no longer defines an ssh
# wrapper, so plain "ssh" stays the OpenSSH client from PATH (or whatever
# alias you set yourself).
unalias sshp 2>/dev/null || true

# OpenSSH options whose argument may follow as a separate word. Only needed to
# separate options from the destination reliably.
__sshp_option_takes_arg() {
    case $1 in
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-P|-p|-Q|-R|-S|-W|-w)
            return 0
            ;;
    esac
    return 1
}

# Argument parser for sshp. Results:
#   __sshp_options          OpenSSH options to pass through
#   __sshp_target           the SSH destination
#   __sshp_extra            words after the destination (remote command)
#   __sshp_force            1 for --force
#   __sshp_help_requested   1 for --help/-h
# Returns 2 if the destination or an option argument is missing.
declare -a __sshp_options=()
declare -a __sshp_extra=()
__sshp_target=''
__sshp_force=0
__sshp_help_requested=0

# WarnWeakCrypto was added in newer OpenSSH releases. The safe default is to
# leave OpenSSH's warning behaviour alone; when suppression is requested, only
# add the option if the installed client actually understands it.
__sshp_warn_weak_crypto_supported() {
    local binary

    binary=$(type -P ssh 2>/dev/null) || return 1
    "$binary" -G -o WarnWeakCrypto=no sshp-option-probe.invalid \
        >/dev/null 2>&1
}

__sshp_add_warn_weak_crypto_option() {
    case ${SSHP_WARN_WEAK_CRYPTO:-yes} in
        yes)
            # OpenSSH's default is to show the warning. Not passing the option
            # also keeps sshp compatible with clients predating the setting.
            return 0
            ;;
        no)
            if __sshp_warn_weak_crypto_supported; then
                __sshp_options+=(-o WarnWeakCrypto=no)
            fi
            return 0
            ;;
        *)
            printf 'sshp: SSHP_WARN_WEAK_CRYPTO must be yes or no.\n' >&2
            return 2
            ;;
    esac
}

# Interactive progress for the comparatively slow sync connection. Status is
# deliberately written only to a real terminal on stderr so sshp stays quiet
# in scripts, command substitutions and redirected output.
__sshp_status_pid=''
__sshp_status_active=0

__sshp_validate_sync_status() {
    case ${SSHP_SYNC_STATUS:-yes} in
        yes|no)
            return 0
            ;;
        *)
            printf 'sshp: SSHP_SYNC_STATUS must be yes or no.\n' >&2
            return 2
            ;;
    esac
}

__sshp_status_terminal() {
    [[ -t 2 && ${TERM-} != dumb ]]
}

__sshp_status_enabled() {
    [[ ${SSHP_SYNC_STATUS:-yes} == yes ]] && __sshp_status_terminal
}

__sshp_status_stop() {
    if [[ -n ${__sshp_status_pid-} ]]; then
        kill "$__sshp_status_pid" 2>/dev/null || true
        wait "$__sshp_status_pid" 2>/dev/null || true
        __sshp_status_pid=''
    fi

    if (( ${__sshp_status_active:-0} )); then
        printf '\r\033[K' >&2
        __sshp_status_active=0
    fi
}

__sshp_status_start() {
    local message=$1

    __sshp_status_stop
    __sshp_status_enabled || return 0

    (
        local -a frames=('|' '/' '-' '\')
        local index=0
        trap 'exit 0' HUP INT TERM

        while :; do
            printf '\r[%s] %s' "${frames[index]}" "$message" >&2
            index=$(( (index + 1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    __sshp_status_pid=$!
    __sshp_status_active=1
}

__sshp_status_finish() {
    local status=$1 message=$2
    local was_active=${__sshp_status_active:-0}

    __sshp_status_stop
    (( was_active )) || return 0

    if (( status == 0 )); then
        printf '[ok] %s\n' "$message" >&2
    else
        printf '[!!] %s\n' "$message" >&2
    fi
}

__sshp_parse_args() {
    local arg option expect_arg=0

    # sshp-owned options come first on purpose: with -o, OpenSSH honours the
    # first occurrence. The weak-crypto warning remains enabled by default; a
    # configured suppression is added here before user-supplied options.
    __sshp_options=()
    __sshp_extra=()
    __sshp_target=''
    __sshp_force=0
    __sshp_help_requested=0
    __sshp_add_warn_weak_crypto_option || return $?
    __sshp_validate_sync_status || return $?

    while (( $# )); do
        arg=$1
        shift

        if (( expect_arg )); then
            __sshp_options+=("$arg")
            expect_arg=0
            continue
        fi

        case $arg in
            --force)
                __sshp_force=1
                continue
                ;;
            --help|-h)
                __sshp_help_requested=1
                return 0
                ;;
            --)
                __sshp_target=${1-}
                (( $# )) && shift
                break
                ;;
            -*)
                __sshp_options+=("$arg")
                option=${arg:0:2}
                if __sshp_option_takes_arg "$option" && (( ${#arg} == 2 )); then
                    expect_arg=1
                fi
                continue
                ;;
        esac

        # The first word that is not an option is the destination.
        __sshp_target=$arg
        break
    done

    __sshp_extra=("$@")

    if (( expect_arg )); then
        printf 'sshp: the argument for the last option is missing.\n' >&2
        return 2
    fi

    if [[ -z $__sshp_target || $__sshp_target == -* ]]; then
        printf 'sshp: exactly one SSH destination is required.\n' >&2
        return 2
    fi

    return 0
}

__sshp_usage() {
    printf 'Usage: sshp [--force] [SSH-OPTIONS ...] user@host\n'
    printf '       sshp [--force] [SSH-OPTIONS ...] SSH-config-alias\n'
    printf '\n'
    printf '  --force   Copy the prompt files even if the signature matches\n'
    printf '  --help    Show this help\n'
}

# Original option list of the installed OpenSSH client. Calling it without
# arguments prints the usage block to stderr and exits with 255.
__sshp_ssh_usage() {
    local binary version

    binary=$(type -P ssh 2>/dev/null)
    if [[ -z $binary ]]; then
        printf 'The OpenSSH client was not found in PATH.\n'
        return 0
    fi

    version=$("$binary" -V 2>&1 | head -n 1)
    printf 'Options passed through to %s' "$binary"
    [[ -z $version ]] || printf ' (%s)' "$version"
    printf ':\n\n'
    "$binary" 2>&1 | sed 's/^/  /' || true
}

__sshp_show_help() {
    __sshp_usage
    printf '\n'
    printf 'SSH options are passed through to OpenSSH unchanged and apply to\n'
    printf 'both the sync connection and the login connection.\n'
    printf 'A remote command is not supported because sshp always opens an\n'
    printf 'interactive session. Use "ssh" for that.\n'
    printf '\n'
    __sshp_ssh_usage
}

# Print a stable description of the effective SSH endpoint used for sync-state
# identity. ssh -G resolves Host aliases and command-line overrides without
# opening a network connection. Only fields that can change the destination or
# its routing are retained so unrelated SSH settings do not force a re-sync.
__sshp_connection_identity() {
    local target=$1 line key value config
    local hostname='' user='' port='' addressfamily=''
    local proxyjump='' proxycommand='' hostkeyalias=''
    shift

    config=$(command ssh -G "$@" "$target" 2>/dev/null) || {
        printf 'sshp: could not resolve effective SSH configuration for %s.\n' \
            "$target" >&2
        return 1
    }

    while IFS= read -r line; do
        key=${line%% *}
        if [[ $line == *' '* ]]; then
            value=${line#* }
        else
            value=''
        fi

        case $key in
            hostname)      hostname=$value ;;
            user)          user=$value ;;
            port)          port=$value ;;
            addressfamily) addressfamily=$value ;;
            proxyjump)     proxyjump=$value ;;
            proxycommand)  proxycommand=$value ;;
            hostkeyalias)  hostkeyalias=$value ;;
        esac
    done <<< "$config"

    if [[ -z $hostname || -z $user || -z $port ]]; then
        printf 'sshp: incomplete effective SSH configuration for %s.\n' \
            "$target" >&2
        return 1
    fi

    printf '%s\n' \
        'sshp-connection-identity=1' \
        "hostname=$hostname" \
        "user=$user" \
        "port=$port" \
        "addressfamily=$addressfamily" \
        "proxyjump=$proxyjump" \
        "proxycommand=$proxycommand" \
        "hostkeyalias=$hostkeyalias"
}

sshp() (
    __sshp_parse_args "$@" || {
        __sshp_usage >&2
        return 2
    }

    if (( __sshp_help_requested )); then
        __sshp_show_help
        return 0
    fi

    if (( ${#__sshp_extra[@]} )); then
        printf 'sshp: a remote command is not supported: %s\n' \
            "${__sshp_extra[0]}" >&2
        printf 'Use "ssh %s %s ..." for that.\n' \
            "$__sshp_target" "${__sshp_extra[0]}" >&2
        return 2
    fi

    local force=$__sshp_force
    local target=$__sshp_target
    local -a ssh_options=("${__sshp_options[@]}")

    local config_root=${BASH_CONFIG_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}
    local state_dir="$HOME/.cache/sshp"
    local archive remote_script signature saved_signature connection_identity
    local connection_crc connection_size state_file temporary_state file option
    local -a sync_files=(
        prompt.sh
        bashrc.d/listing.sh
        bashrc.d/prompt-core.sh
        bashrc.d/prompt-gruvbox.sh
    )

    for file in "${sync_files[@]}"; do
        # The list is handed to the remote script as one space-separated,
        # single-quoted string, so the names have to stay boring. Checking it
        # here keeps that embedding provably safe instead of merely true by
        # convention.
        [[ $file != *[^[:alnum:]./_-]* ]] || {
            printf 'sshp: %s is not a usable sync file name.\n' "$file" >&2
            return 1
        }
        [[ -r "$config_root/$file" ]] || {
            printf 'sshp: %s is missing or not readable.\n' "$config_root/$file" >&2
            return 1
        }
        bash -n "$config_root/$file" || return 1
    done

    command -v cksum >/dev/null 2>&1 || {
        printf 'sshp: cksum is missing on the local system.\n' >&2
        return 1
    }

    signature=$(
        {
            printf '%s\n' 'sshp-sync-format=5'
            for file in "${sync_files[@]}"; do
                printf '%s\n' "$file"
                cksum "$config_root/$file"
            done
        } | cksum
    ) || return 1

    connection_identity=$(__sshp_connection_identity "$target" "${ssh_options[@]}") || return 1
    read -r connection_crc connection_size <<EOF
$(printf '%s' "$connection_identity" | cksum)
EOF
    # Prefix the new key format so legacy target-only cache entries can never
    # be mistaken for connection-aware state after an upgrade.
    state_file="$state_dir/connection-v1_${connection_crc}_${connection_size}.state"
    [[ ! -r $state_file ]] || IFS= read -r saved_signature < "$state_file"

    if (( ! force )) && [[ ${saved_signature-} == "$signature" ]]; then
        command ssh "${ssh_options[@]}" "$target"
        return
    fi

    __sshp_status_start 'sshp: preparing prompt package...'

    archive=$(mktemp -t sshp-prompt.XXXXXX.tgz) || {
        __sshp_status_finish 1 'sshp: prompt synchronization failed'
        return 1
    }

    __sshp_sync_cleanup() {
        __sshp_status_stop
        [[ -z ${archive-} ]] || rm -f -- "$archive"
    }
    trap '__sshp_sync_cleanup' EXIT
    trap '__sshp_sync_cleanup; exit 129' HUP
    trap '__sshp_sync_cleanup; exit 130' INT
    trap '__sshp_sync_cleanup; exit 143' TERM

    tar -czf "$archive" -C "$config_root" "${sync_files[@]}" || {
        __sshp_status_finish 1 'sshp: prompt synchronization failed'
        return 1
    }

    # The heredoc below is deliberately quoted, so nothing in it expands
    # locally. The one value the remote side needs from here is the list of
    # synced files, which is prepended as a plain assignment: sync_files stays
    # defined in exactly one place, and adding a file to the sync is a one-line
    # change plus the format bump.
    read -r -d '' remote_script <<'REMOTE' || true
set -eu
for command_name in tar bash grep mktemp touch rm; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf "sshp: %s is missing on the destination.\n" "$command_name" >&2
        exit 1
    }
done

umask 077
cache_dir="$HOME/.cache"
prompt_dir="$cache_dir/ssh-prompt"
bashrc="$HOME/.bashrc"
bashrc_backup="$HOME/.bashrc.before-sshp"
start_marker="# >>> sshp managed prompt >>>"
staging=''
prompt_backup=''

__sshp_remote_cleanup() {
    if test -n "$staging"; then
        rm -rf -- "$staging"
    fi

    if test -n "$prompt_backup"; then
        if ! test -e "$prompt_dir" && ! test -L "$prompt_dir"; then
            mv -- "$prompt_backup" "$prompt_dir" 2>/dev/null || true
        else
            rm -rf -- "$prompt_backup"
        fi
    fi
}
trap '__sshp_remote_cleanup' EXIT HUP INT TERM

touch "$HOME/.hushlogin"
mkdir -p "$cache_dir"
staging=$(mktemp -d "$cache_dir/.ssh-prompt.new.XXXXXX")
tar --no-same-owner -xzf - -C "$staging"
# sync_files is prepended to this script by the local side, so the list exists
# once. Word splitting is the point here; the local side validates the names.
for sync_file in $sync_files; do
    bash -n "$staging/$sync_file"
done

# Only publish a fully extracted and syntax-checked tree. The old prompt stays
# live until this point; if activation fails, the EXIT trap restores it.
if test -e "$prompt_dir" || test -L "$prompt_dir"; then
    prompt_backup=$(mktemp "$cache_dir/.ssh-prompt.old.XXXXXX")
    rm -f -- "$prompt_backup"
    mv -- "$prompt_dir" "$prompt_backup"
fi

if mv -- "$staging" "$prompt_dir"; then
    staging=''
else
    if test -n "$prompt_backup"; then
        mv -- "$prompt_backup" "$prompt_dir" 2>/dev/null || true
        prompt_backup=''
    fi
    exit 1
fi

if test -n "$prompt_backup"; then
    rm -rf -- "$prompt_backup"
    prompt_backup=''
fi
trap - EXIT HUP INT TERM

if ! { test -f "$bashrc" && grep -Fqx "$start_marker" "$bashrc"; }; then
    if test -f "$bashrc" && ! test -e "$bashrc_backup"; then
        cp -p "$bashrc" "$bashrc_backup"
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
    remote_script="sync_files='${sync_files[*]}'
$remote_script"

    __sshp_status_start 'sshp: uploading and installing prompt...'
    # sshd may send a pre-authentication SSH_MSG_USERAUTH_BANNER before the
    # remote script starts. Suppress that banner only for this internal sync
    # connection; the real interactive login below keeps the user's normal
    # SSH logging and therefore still displays the banner once. Put LogLevel
    # first because OpenSSH keeps the first -o value.
    local -a sync_ssh_options=()
    for option in "${ssh_options[@]}"; do
        case $option in
            -v|-vv|-vvv)
                # -v changes LogLevel directly and would re-enable auth banners.
                continue
                ;;
        esac
        sync_ssh_options+=("$option")
    done
    if ! command ssh -T -o RemoteCommand=none -o LogLevel=ERROR \
        "${sync_ssh_options[@]}" "$target" "$remote_script" < "$archive"; then
        __sshp_status_finish 1 'sshp: prompt synchronization failed'
        printf 'sshp: sync or .bashrc update failed.\n' >&2
        return 1
    fi

    __sshp_status_start 'sshp: saving sync state...'
    mkdir -p "$state_dir" || {
        __sshp_status_finish 1 'sshp: prompt synchronization failed'
        return 1
    }
    temporary_state=$(mktemp "$state_dir/.state.XXXXXX") || {
        __sshp_status_finish 1 'sshp: prompt synchronization failed'
        return 1
    }
    printf '%s\n' "$signature" > "$temporary_state" || {
        __sshp_status_finish 1 'sshp: prompt synchronization failed'
        return 1
    }
    mv -f "$temporary_state" "$state_file" || {
        __sshp_status_finish 1 'sshp: prompt synchronization failed'
        return 1
    }
    __sshp_status_finish 0 'sshp: prompt synchronized'
    command ssh "${ssh_options[@]}" "$target"
)
