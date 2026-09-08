#!/usr/bin/env bash

# Login ueber die eindeutige NR-Spalte von known-hosts.
# Zusaetzliche Argumente werden wie bei "ssh HOST ..." als Remote-Kommando
# hinter dem Ziel an OpenSSH weitergereicht.
ssh_by_number() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local nr=${1-}
    local gid alias target host port=''
    local -a ssh_args=()

    case $nr in
        --help|-h|'')
            printf 'Aufruf: ssh-nr NR [REMOTE-KOMMANDO ...]\n'
            printf '        ssh-nr --list\n'
            printf '\nNR ist die eindeutige Zielnummer aus der ersten Spalte von known-hosts.\n'
            [[ -n $nr ]] && return 0 || return 2
            ;;
        --list|-l)
            shift
            (( $# == 0 )) || {
                printf 'ssh-nr: --list akzeptiert keine weiteren Argumente.\n' >&2
                return 2
            }
            ssh_known_hosts
            return $?
            ;;
    esac

    [[ $nr =~ ^[1-9][0-9]*$ ]] || {
        printf 'ssh-nr: ungueltige Zielnummer: %q\n' "$nr" >&2
        return 2
    }
    shift

    [[ -r $known_hosts_file ]] || {
        printf 'ssh-nr: %s fehlt oder ist nicht lesbar.\n' "$known_hosts_file" >&2
        return 1
    }

    __kh_groups_build "$known_hosts_file" "$config" || return

    gid=$((nr - 1))
    if (( gid < 0 || gid >= __kh_group_count )); then
        printf 'ssh-nr: Zielnummer %s existiert nicht.\n' "$nr" >&2
        printf 'Verfuegbare Ziele mit "known-hosts" anzeigen.\n' >&2
        return 1
    fi

    alias=${__kh_group_alias[$gid]}
    target=${__kh_group_target[$gid]}

    # Wenn ein Alias vorhanden ist, immer ueber ihn verbinden. Dadurch greifen
    # User, Port, ProxyJump, IdentityFile usw. exakt wie in ~/.ssh/config.
    if [[ $alias != '-' ]]; then
        if [[ $config != "$HOME/.ssh/config" ]]; then
            ssh_args+=(-F "$config")
        fi
        command ssh "${ssh_args[@]}" "$alias" "$@"
        return $?
    fi

    # Direkte known_hosts-Ziele muessen in eine gueltige ssh-Zielsyntax
    # ueberfuehrt werden. Marker, Hashes und Hostlisten sind nicht eindeutig.
    case $target in
        @*|'[gehashter Hostname]'*|*','*|*'*'*|*'?'*|*'!'*)
            printf 'ssh-nr: Zielnummer %s ist kein direkt verbindbares SSH-Ziel: %s\n' \
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
        ssh_args+=(-F "$config")
    fi
    [[ -z $port ]] || ssh_args+=(-p "$port")

    command ssh "${ssh_args[@]}" "$host" "$@"
}
