#!/usr/bin/env bash

# Standardansicht ohne externe Prozesse; Fingerabdruecke optional gesammelt.
ssh_known_hosts() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local filter=${1-}
    local line line_number=0 first second third fourth remainder
    local marker hosts key_type key display_hosts
    local found=0

    if (( $# > 1 )); then
        printf 'Aufruf: known-hosts [HOSTFILTER | --fingerprints]\n' >&2
        return 2
    fi

    [[ -r $known_hosts_file ]] || {
        printf 'known-hosts: %s fehlt oder ist nicht lesbar.\n' \
            "$known_hosts_file" >&2
        return 1
    }

    if [[ $filter == --fingerprints ]]; then
        # Originalausgabe von OpenSSH: Bits, Fingerabdruck, Ziel, Schluesseltyp.
        ssh-keygen -l -E sha256 -f "$known_hosts_file"
        return $?
    fi

    printf '\e[2m%-6s %-42s %s\e[0m\n' \
        'ZEILE' 'ZIEL' 'SCHLÜSSEL'

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number+=1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue

        read -r first second third fourth remainder <<< "$line"
        marker=''
        if [[ $first == @* ]]; then
            marker=$first
            hosts=$second
            key_type=$third
            key=$fourth
        else
            hosts=$first
            key_type=$second
            key=$third
        fi

        [[ -n $hosts && -n $key_type && -n $key ]] || continue

        if [[ $hosts == '|1|'* ]]; then
            display_hosts='[gehashter Hostname]'
        else
            display_hosts=$hosts
        fi
        [[ -z $marker ]] || display_hosts="$marker $display_hosts"

        if [[ -n $filter && ${display_hosts,,} != *"${filter,,}"* ]]; then
            continue
        fi

        key_type=${key_type#ssh-}
        key_type=${key_type^^}

        printf '\e[2m%-6d\e[0m \e[36m%-42s\e[0m \e[33m%s\e[0m\n' \
            "$line_number" "$display_hosts" "$key_type"
        found=1
    done < "$known_hosts_file"

    if (( ! found )); then
        if [[ -n $filter ]]; then
            printf 'Keine lesbaren Einträge für „%s“ gefunden.\n' "$filter"
        else
            printf 'Keine Einträge gefunden.\n'
        fi
    fi
    return 0
}

unalias known-hosts ssh-known-hosts 2>/dev/null || true
alias known-hosts='ssh_known_hosts'
alias ssh-known-hosts='ssh_known_hosts'
