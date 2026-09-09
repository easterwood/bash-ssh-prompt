#!/usr/bin/env bash

# Login ueber die eindeutige NR-Spalte von known-hosts.
# Nach der Zielaufloesung wird sshp verwendet, damit ssh-nr dasselbe
# Verbindungsverhalten wie ein direkter sshp-Aufruf hat.

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
            # Ueber eine Variable aufrufen, damit ein eventuell gleichnamiger
            # Alias beim Parsen dieser Datei nicht versehentlich expandiert.
            local runner=sshp
            "$runner" "$@"
            return $?
            ;;
        alias)
            # Aliase werden vor Parameterexpansion verarbeitet und koennen
            # deshalb nicht ueber "$runner" aufgerufen werden. Die Argumente
            # werden mit %q shell-sicher an einen eval-Aufruf angehaengt.
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
            printf 'ssh-nr: sshp ist weder als Funktion, Alias noch als Kommando verfuegbar.\n' >&2
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
            printf 'Aufruf: ssh-nr NR [SSH-OPTIONEN ...]\n'
            printf '        ssh-nr --list\n'
            printf '\nNR ist die eindeutige Zielnummer aus der ersten Spalte von known-hosts.\n'
            printf 'Das aufgeloeste Ziel wird anschliessend ueber sshp verbunden.\n'
            printf 'SSH-Optionen werden vor dem Ziel an sshp uebergeben.\n'
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
            sshp_args+=(-F "$config")
        fi
        sshp_args+=("$@")
        sshp_args+=("$alias")
        __ssh_by_number_run_sshp "${sshp_args[@]}"
        return $?
    fi

    # Direkte known_hosts-Ziele muessen in eine gueltige SSH-Zielsyntax
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
        sshp_args+=(-F "$config")
    fi
    [[ -z $port ]] || sshp_args+=(-p "$port")
    sshp_args+=("$@")
    sshp_args+=("$host")

    __ssh_by_number_run_sshp "${sshp_args[@]}"
}
