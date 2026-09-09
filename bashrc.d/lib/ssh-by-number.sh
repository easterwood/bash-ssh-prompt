#!/usr/bin/env bash

# Log in via the unique NR column of known-hosts.
# Once the target is resolved, sshp is used so that ssh-nr behaves exactly like
# a direct sshp call.

__ssh_by_number_run_sshp() {
    local kind rc arg command_line='sshp'
    local had_expand_aliases=0

    if alias sshp >/dev/null 2>&1; then
        kind=alias
    else
        kind=$(type -t sshp 2>/dev/null || true)
    fi

    case $kind in
        function|file|builtin)
            # Call through a variable so an alias of the same name is not
            # expanded accidentally while this file is parsed.
            local runner=sshp
            "$runner" "$@"
            return $?
            ;;
        alias)
            # Aliases are processed before parameter expansion and therefore
            # cannot be called through "$runner". The arguments are appended to
            # an eval call in a shell-safe way using %q.
            shopt -q expand_aliases && had_expand_aliases=1
            shopt -s expand_aliases

            for arg in "$@"; do
                printf -v command_line '%s %q' "$command_line" "$arg"
            done

            eval "$command_line"
            rc=$?

            (( had_expand_aliases )) || shopt -u expand_aliases
            return "$rc"
            ;;
        *)
            printf 'ssh-nr: sshp is available neither as a function, an alias nor a command.\n' >&2
            return 127
            ;;
    esac
}

ssh_by_number() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local nr=${1-}
    local gid alias target host port=''
    local -a sshp_args=()

    case $nr in
        --help|-h|'')
            printf 'Usage: ssh-nr NR [SSH-OPTIONS ...]\n'
            printf '       ssh-nr --list\n'
            printf '\nNR is the unique target number from the first column of known-hosts.\n'
            printf 'The resolved target is then connected through sshp.\n'
            printf 'SSH options are passed to sshp ahead of the destination.\n'
            [[ -n $nr ]] && return 0 || return 2
            ;;
        --list|-l)
            shift
            (( $# == 0 )) || {
                printf 'ssh-nr: --list does not accept any further arguments.\n' >&2
                return 2
            }
            ssh_known_hosts
            return $?
            ;;
    esac

    [[ $nr =~ ^[1-9][0-9]*$ ]] || {
        printf 'ssh-nr: invalid target number: %q\n' "$nr" >&2
        return 2
    }
    shift

    [[ -r $known_hosts_file ]] || {
        printf 'ssh-nr: %s is missing or not readable.\n' "$known_hosts_file" >&2
        return 1
    }

    __kh_groups_build "$known_hosts_file" "$config" || return

    gid=$((nr - 1))
    if (( gid < 0 || gid >= __kh_group_count )); then
        printf 'ssh-nr: target number %s does not exist.\n' "$nr" >&2
        printf 'Show the available targets with "known-hosts".\n' >&2
        return 1
    fi

    alias=${__kh_group_alias[$gid]}
    target=${__kh_group_target[$gid]}

    # If an alias exists, always connect through it. That way user, port,
    # ProxyJump, IdentityFile and so on apply exactly as in ~/.ssh/config.
    if [[ $alias != '-' ]]; then
        if [[ $config != "$HOME/.ssh/config" ]]; then
            sshp_args+=(-F "$config")
        fi
        sshp_args+=("$@")
        sshp_args+=("$alias")
        __ssh_by_number_run_sshp "${sshp_args[@]}"
        return $?
    fi

    # Direct known_hosts targets have to be converted into valid SSH
    # destination syntax. Markers, hashes and host lists are not unambiguous.
    case $target in
        @*|'[hashed hostname]'*|*','*|*'*'*|*'?'*|*'!'*)
            printf 'ssh-nr: target number %s is not a directly connectable SSH destination: %s\n' \
                "$nr" "$target" >&2
            return 1
            ;;
    esac

    host=$target
    if [[ $target =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
    fi

    if [[ $config != "$HOME/.ssh/config" ]]; then
        sshp_args+=(-F "$config")
    fi
    [[ -z $port ]] || sshp_args+=(-p "$port")
    sshp_args+=("$@")
    sshp_args+=("$host")

    __ssh_by_number_run_sshp "${sshp_args[@]}"
}
