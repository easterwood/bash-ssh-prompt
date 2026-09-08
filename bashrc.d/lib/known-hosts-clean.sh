#!/usr/bin/env bash

# Bereinigung fuer known_hosts.
# Standardmaessig nur Dry-Run; mit --apply wird nach einem Backup geschrieben.
declare -A __kh_clean_seen=()

__kh_clean_scan_type_for() {
    case $1 in
        ssh-ed25519)    printf '%s\n' 'ed25519' ;;
        ssh-rsa)        printf '%s\n' 'rsa' ;;
        ecdsa-sha2-*)   printf '%s\n' 'ecdsa' ;;
        ssh-ed25519-sk) printf '%s\n' 'ed25519-sk' ;;
        ecdsa-sk-*)     printf '%s\n' 'ecdsa-sk' ;;
        *) return 1 ;;
    esac
}

# Return:
#   0 = Key stimmt
#   1 = Key stimmt nicht / nicht mehr vorhanden
#   2 = Host nicht erreichbar / kein Key geliefert
#   3 = Keytyp nicht unterstuetzt
__kh_clean_check_entry() {
    local host=$1 port=$2 keytype=$3 stored_key=$4 timeout=$5
    local scan_type scanned current_key

    scan_type=$(__kh_clean_scan_type_for "$keytype") || return 3

    scanned=$(
        command ssh-keyscan \
            -T "$timeout" \
            -p "$port" \
            -t "$scan_type" \
            "$host" 2>/dev/null |
        awk -v type="$keytype" '$2 == type { print $3 }'
    )

    [[ -n $scanned ]] || return 2

    while IFS= read -r current_key; do
        [[ $current_key == "$stored_key" ]] && return 0
    done <<< "$scanned"

    return 1
}

# Schreibt eine Zeile genau einmal in die temporaere Datei.
# Kommentare bzw. unterschiedliche Abstaende ausserhalb der relevanten Felder
# beeinflussen die Duplikaterkennung nicht.
__kh_clean_keep_line() {
    local line=$1 tmp=$2
    local marker='' hosts keytype stored_key rest identity

    read -r hosts keytype stored_key rest <<< "$line"

    if [[ $hosts == @* ]]; then
        read -r marker hosts keytype stored_key rest <<< "$line"
    fi

    # Unvollstaendige Eintraege unveraendert behalten.
    if [[ -z $hosts || -z $keytype || -z $stored_key ]]; then
        printf '%s\n' "$line" >> "$tmp"
        return 0
    fi

    identity="$marker $hosts $keytype $stored_key"

    if [[ -n ${__kh_clean_seen["$identity"]+x} ]]; then
        printf 'DUPLICATE -> REMOVE: %s %s\n' "$hosts" "$keytype"
        return 0
    fi

    __kh_clean_seen["$identity"]=1
    printf '%s\n' "$line" >> "$tmp"
}

__kh_clean_usage() {
    cat <<'EOF_USAGE'
Aufruf: known-hosts-clean [--apply]

Prueft nicht gehashte known_hosts-Eintraege mit ssh-keyscan.
Ohne --apply wird nur angezeigt, was entfernt wuerde.
Mit --apply wird vor der Aenderung ein Backup angelegt.

Umgebungsvariablen:
  SSH_KNOWN_HOSTS_FILE           Pfad zu known_hosts
  SSH_KNOWN_HOSTS_CLEAN_TIMEOUT  ssh-keyscan Timeout in Sekunden (Standard: 3)
EOF_USAGE
}

ssh_known_hosts_clean() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local timeout=${SSH_KNOWN_HOSTS_CLEAN_TIMEOUT:-3}
    local apply=0
    local tmp backup line hosts keytype stored_key rest host port result
    local rc=0

    case ${1-} in
        '') ;;
        --apply) apply=1 ;;
        -h|--help)
            __kh_clean_usage
            return 0
            ;;
        *)
            __kh_clean_usage >&2
            return 2
            ;;
    esac

    (( $# <= 1 )) || {
        __kh_clean_usage >&2
        return 2
    }

    [[ $timeout =~ ^[1-9][0-9]*$ ]] || {
        printf 'known-hosts-clean: ungueltiger Timeout: %s\n' "$timeout" >&2
        return 2
    }

    [[ -f $known_hosts_file && -r $known_hosts_file ]] || {
        printf 'known-hosts-clean: known_hosts nicht gefunden oder nicht lesbar: %s\n' \
            "$known_hosts_file" >&2
        return 1
    }

    if (( apply )) && [[ ! -w $known_hosts_file ]]; then
        printf 'known-hosts-clean: known_hosts ist nicht beschreibbar: %s\n' \
            "$known_hosts_file" >&2
        return 1
    fi

    command -v ssh-keyscan >/dev/null 2>&1 || {
        printf 'known-hosts-clean: ssh-keyscan wurde nicht gefunden.\n' >&2
        return 1
    }
    command -v awk >/dev/null 2>&1 || {
        printf 'known-hosts-clean: awk wurde nicht gefunden.\n' >&2
        return 1
    }

    tmp=$(mktemp) || {
        printf 'known-hosts-clean: temporaere Datei konnte nicht angelegt werden.\n' >&2
        return 1
    }

    __kh_clean_seen=()

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}

        # Leerzeilen und Kommentare unveraendert behalten.
        if [[ $line =~ ^[[:space:]]*(#|$) ]]; then
            printf '%s\n' "$line" >> "$tmp" || { rc=1; break; }
            continue
        fi

        # Marker nicht automatisch pruefen oder veraendern.
        if [[ $line == @* ]]; then
            printf '%s\n' 'SKIP    marker entry'
            __kh_clean_keep_line "$line" "$tmp" || { rc=1; break; }
            continue
        fi

        read -r hosts keytype stored_key rest <<< "$line"

        # Gehashte Hosts koennen nicht zurueck in Hostnamen umgewandelt werden.
        # Exakte Duplikate werden trotzdem entfernt.
        if [[ $hosts == '|1|'* ]]; then
            printf '%s\n' 'SKIP    hashed entry'
            __kh_clean_keep_line "$line" "$tmp" || { rc=1; break; }
            continue
        fi

        # Komplexe Host-Angaben nicht automatisch pruefen.
        if [[ $hosts == *','* ||
              $hosts == *'*'* ||
              $hosts == *'?'* ||
              $hosts == *'!'* ]]; then
            printf 'SKIP    complex host: %s\n' "$hosts"
            __kh_clean_keep_line "$line" "$tmp" || { rc=1; break; }
            continue
        fi

        host=$hosts
        port=22

        # OpenSSH known_hosts Syntax fuer nicht-standardmaessige Ports.
        if [[ $hosts =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[2]}
        fi

        printf 'CHECK   %-35s %-28s ' "$host:$port" "$keytype"

        __kh_clean_check_entry "$host" "$port" "$keytype" "$stored_key" "$timeout"
        result=$?

        case $result in
            0)
                printf '%s\n' 'OK'
                __kh_clean_keep_line "$line" "$tmp" || { rc=1; break; }
                ;;
            1)
                printf '%s\n' 'KEY MISMATCH -> REMOVE'
                (( apply )) || __kh_clean_keep_line "$line" "$tmp" || { rc=1; break; }
                ;;
            2)
                printf '%s\n' 'UNREACHABLE -> REMOVE'
                (( apply )) || __kh_clean_keep_line "$line" "$tmp" || { rc=1; break; }
                ;;
            3)
                printf '%s\n' 'UNSUPPORTED KEY TYPE -> KEEP'
                __kh_clean_keep_line "$line" "$tmp" || { rc=1; break; }
                ;;
        esac
    done < "$known_hosts_file"

    if (( rc != 0 )); then
        rm -f -- "$tmp"
        printf 'known-hosts-clean: temporaere Ausgabe konnte nicht geschrieben werden.\n' >&2
        return "$rc"
    fi

    if (( apply )); then
        backup="${known_hosts_file}.bak.$(date +%Y%m%d-%H%M%S)"

        if ! command cp -- "$known_hosts_file" "$backup"; then
            rm -f -- "$tmp"
            printf 'known-hosts-clean: Backup konnte nicht angelegt werden.\n' >&2
            return 1
        fi

        if ! command cat -- "$tmp" > "$known_hosts_file"; then
            rm -f -- "$tmp"
            printf 'known-hosts-clean: known_hosts konnte nicht geschrieben werden.\n' >&2
            printf 'Backup: %s\n' "$backup" >&2
            return 1
        fi

        rm -f -- "$tmp"

        # Die Datei wurde geaendert: beide Caches fuer die aktuelle Shell
        # ungueltig machen. Die Funktionspruefungen halten das Modul eigenstaendig.
        declare -F __kh_cache_invalidate >/dev/null && __kh_cache_invalidate
        declare -F __ssh_completion_cache_invalidate >/dev/null && __ssh_completion_cache_invalidate

        printf '\nknown_hosts bereinigt.\n'
        printf 'Backup: %s\n' "$backup"
    else
        rm -f -- "$tmp"
        printf '\nDRY RUN - known_hosts wurde nicht veraendert.\n\n'
        printf 'Zum tatsaechlichen Bereinigen:\n'
        printf '  known-hosts-clean --apply\n'
    fi

    return 0
}
