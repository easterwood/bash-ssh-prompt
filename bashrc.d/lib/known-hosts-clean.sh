#!/usr/bin/env bash

# Bereinigung fuer known_hosts und die primaere SSH-Benutzerkonfiguration.
# Standardmaessig nur Dry-Run; mit --apply werden nach Backups beide Dateien
# geschrieben. Include-Dateien aus der SSH-Konfiguration werden nicht veraendert.
declare -A __kh_clean_seen=()
declare -A __kh_clean_target_checked=()
declare -A __kh_clean_target_keep=()
declare -A __kh_clean_target_mismatch=()
declare -A __kh_clean_target_unreachable=()
declare -A __kh_clean_target_stale=()
declare -A __kh_clean_target_reason=()
declare -A __kh_clean_endpoint_reachable=()
declare -A __kh_clean_endpoint_unreachable=()

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

__kh_clean_reset_state() {
    __kh_clean_seen=()
    __kh_clean_target_checked=()
    __kh_clean_target_keep=()
    __kh_clean_target_mismatch=()
    __kh_clean_target_unreachable=()
    __kh_clean_target_stale=()
    __kh_clean_target_reason=()
    __kh_clean_endpoint_reachable=()
    __kh_clean_endpoint_unreachable=()
}

# Merkt sich das Ergebnis eines pruefbaren known_hosts-Eintrags pro Lookup-Ziel.
# Ein Ziel gilt spaeter nur dann als veraltet, wenn mindestens ein Eintrag
# MISMATCH/UNREACHABLE war und kein Eintrag fuer dieses Ziel behalten wird.
__kh_clean_record_target_result() {
    local lookup=$1 result=$2

    [[ -n $lookup ]] || return 0
    __kh_clean_target_checked["$lookup"]=1

    case $result in
        0|3) __kh_clean_target_keep["$lookup"]=1 ;;
        1)   __kh_clean_target_mismatch["$lookup"]=1 ;;
        2)   __kh_clean_target_unreachable["$lookup"]=1 ;;
    esac
}

__kh_clean_finalize_targets() {
    local lookup reason

    for lookup in "${!__kh_clean_target_checked[@]}"; do
        [[ -z ${__kh_clean_target_keep["$lookup"]+x} ]] || continue
        [[ -n ${__kh_clean_target_mismatch["$lookup"]+x} ||
           -n ${__kh_clean_target_unreachable["$lookup"]+x} ]] || continue

        __kh_clean_target_stale["$lookup"]=1
        reason=''

        if [[ -n ${__kh_clean_target_mismatch["$lookup"]+x} ]]; then
            reason='KEY MISMATCH'
        fi
        if [[ -n ${__kh_clean_target_unreachable["$lookup"]+x} ]]; then
            if [[ -n $reason ]]; then
                reason+=' / UNREACHABLE'
            else
                reason='UNREACHABLE'
            fi
        fi

        __kh_clean_target_reason["$lookup"]=$reason
    done
}

# Schreibt eine known_hosts-Zeile genau einmal in die temporaere Datei.
# Kommentare bzw. unterschiedliche Abstaende ausserhalb der relevanten Felder
# beeinflussen die Duplikaterkennung nicht.
# Return 10 bedeutet: exaktes Duplikat, Zeile wurde bewusst nicht geschrieben.
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
        return $?
    fi

    identity="$marker $hosts $keytype $stored_key"

    if [[ -n ${__kh_clean_seen["$identity"]+x} ]]; then
        printf 'DUPLICATE -> REMOVE: %s %s\n' "$hosts" "$keytype"
        return 10
    fi

    __kh_clean_seen["$identity"]=1
    printf '%s\n' "$line" >> "$tmp"
}

# Loest einen konkreten Host-Alias so auf, wie known-hosts es ebenfalls tut.
# Ergebnisse:
#   __kh_clean_resolved_host    tatsaechliches Verbindungsziel
#   __kh_clean_resolved_port    effektiver Port
#   __kh_clean_resolved_lookup  known_hosts-Lookup inkl. HostKeyAlias/Port
__kh_clean_resolve_alias() {
    local config=$1 alias=$2
    local resolved field value host='' port=22 keyalias=''

    __kh_clean_resolved_host=''
    __kh_clean_resolved_port=22
    __kh_clean_resolved_lookup=''

    if [[ $config == "$HOME/.ssh/config" ]]; then
        resolved=$(command ssh -G -T "$alias" 2>/dev/null) || return 1
    else
        resolved=$(command ssh -G -T -F "$config" "$alias" 2>/dev/null) || return 1
    fi

    while read -r field value; do
        case $field in
            hostname)     host=$value ;;
            port)         port=$value ;;
            hostkeyalias) keyalias=$value ;;
        esac
    done <<< "$resolved"

    [[ -n $host ]] || return 1
    [[ $port =~ ^[0-9]+$ ]] || return 1

    __kh_clean_resolved_host=$host
    __kh_clean_resolved_port=$port
    __kh_clean_resolved_lookup=$host
    [[ -z $keyalias || $keyalias == none ]] || __kh_clean_resolved_lookup=$keyalias
    [[ $port == 22 ]] || __kh_clean_resolved_lookup="[$__kh_clean_resolved_lookup]:$port"
    return 0
}

# Prueft ein Config-Ziel, wenn known_hosts fuer dieses Ziel keine belastbare
# Entscheidung geliefert hat. Es genuegt irgendein von ssh-keyscan gelieferter
# Host-Key; die eigentliche Key-Uebereinstimmung wird weiterhin ueber
# known_hosts geprueft. Ergebnisse werden pro Host/Port gecacht.
# Return:
#   0 = erreichbar / mindestens ein Host-Key geliefert
#   2 = nicht erreichbar / kein Host-Key geliefert
__kh_clean_check_endpoint() {
    local host=$1 port=$2 timeout=$3
    local endpoint scanned

    endpoint="[$host]:$port"

    if [[ -n ${__kh_clean_endpoint_reachable["$endpoint"]+x} ]]; then
        return 0
    fi
    if [[ -n ${__kh_clean_endpoint_unreachable["$endpoint"]+x} ]]; then
        return 2
    fi

    scanned=$(
        command ssh-keyscan \
            -T "$timeout" \
            -p "$port" \
            "$host" 2>/dev/null
    )

    if [[ -n $scanned ]]; then
        __kh_clean_endpoint_reachable["$endpoint"]=1
        return 0
    fi

    __kh_clean_endpoint_unreachable["$endpoint"]=1
    return 2
}

# Zerlegt eine Host-Zeile der SSH-Konfiguration in konkrete, sicher
# bearbeitbare Aliase. Bei Wildcards/Negationen/Quotes wird nichts umgeschrieben.
# Ergebnisarrays:
#   __kh_clean_cfg_tokens       alle Host-Tokens
#   __kh_clean_cfg_keep_tokens  nicht zu entfernende Tokens
#   __kh_clean_cfg_drop_tokens  zu entfernende Tokens
# Globals:
#   __kh_clean_cfg_complex      1 bei komplexer Host-Zeile
__kh_clean_classify_host_line() {
    local config=$1 content=$2 timeout=$3
    local keyword token lookup host port
    local -a words=()

    __kh_clean_cfg_tokens=()
    __kh_clean_cfg_keep_tokens=()
    __kh_clean_cfg_drop_tokens=()
    __kh_clean_cfg_drop_lookups=()
    __kh_clean_cfg_drop_reasons=()
    __kh_clean_cfg_complex=0

    content=${content/=/ }
    read -r -a words <<< "$content"
    ((${#words[@]} >= 2)) || return 1

    keyword=${words[0],,}
    [[ $keyword == host ]] || return 1

    for token in "${words[@]:1}"; do
        __kh_clean_cfg_tokens+=("$token")

        # Nur einfache, konkrete Host-Aliase automatisch aendern.
        if [[ -z $token || $token == '!'* ||
              $token == *'*'* || $token == *'?'* || $token == *'['* ||
              $token == *'"'* || $token == *"'"* ||
              $token == *[[:space:][:cntrl:]]* ]]; then
            __kh_clean_cfg_complex=1
            __kh_clean_cfg_keep_tokens+=("$token")
            continue
        fi

        if ! __kh_clean_resolve_alias "$config" "$token"; then
            # Kann ssh -G den Alias nicht auswerten, wird er aus Sicherheitsgruenden behalten.
            __kh_clean_cfg_keep_tokens+=("$token")
            continue
        fi

        lookup=$__kh_clean_resolved_lookup
        host=$__kh_clean_resolved_host
        port=$__kh_clean_resolved_port

        if [[ -n ${__kh_clean_target_stale["$lookup"]+x} ]]; then
            __kh_clean_cfg_drop_tokens+=("$token")
            __kh_clean_cfg_drop_lookups+=("$lookup")
            __kh_clean_cfg_drop_reasons+=("${__kh_clean_target_reason["$lookup"]}")
            continue
        fi

        # Wurde das Ziel anhand eines pruefbaren known_hosts-Eintrags bewertet
        # und nicht als veraltet markiert, bleibt die Config bestehen. Das gilt
        # insbesondere bei einem gueltigen oder nicht unterstuetzten Keytyp.
        if [[ -n ${__kh_clean_target_checked["$lookup"]+x} ]]; then
            __kh_clean_cfg_keep_tokens+=("$token")
            continue
        fi

        # Fuer Config-Ziele ohne pruefbaren known_hosts-Eintrag (z. B. noch nie
        # verbunden oder nur gehashter Eintrag) wird die Erreichbarkeit direkt
        # ueber das tatsaechliche HostName/Port-Ziel geprueft.
        if __kh_clean_check_endpoint "$host" "$port" "$timeout"; then
            __kh_clean_cfg_keep_tokens+=("$token")
        else
            __kh_clean_cfg_drop_tokens+=("$token")
            __kh_clean_cfg_drop_lookups+=("$lookup")
            __kh_clean_cfg_drop_reasons+=('UNREACHABLE')
        fi
    done

    return 0
}

# Erstellt die bereinigte Version der primaeren SSH-Konfiguration.
# Include-Dateien werden bewusst nicht veraendert.
__kh_clean_build_config() {
    local config=$1 tmp=$2 timeout=$3
    local line code content header_keyword indent comment
    local i j block_end changes=0
    local drop_index
    local -a lines=()

    __kh_clean_config_changes=0

    [[ -f $config && -r $config ]] || return 0

    while IFS= read -r line || [[ -n $line ]]; do
        lines+=("${line%$'\r'}")
    done < "$config"

    for ((i=0; i<${#lines[@]}; i++)); do
        line=${lines[$i]}
        code=${line%%#*}
        content=$code
        content=${content#"${content%%[![:space:]]*}"}
        header_keyword=${content%%[[:space:]=]*}
        header_keyword=${header_keyword,,}

        if [[ $header_keyword != host ]]; then
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        fi

        if ! __kh_clean_classify_host_line "$config" "$code" "$timeout"; then
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        fi

        ((${#__kh_clean_cfg_drop_tokens[@]})) || {
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        }

        if (( __kh_clean_cfg_complex )); then
            printf 'CONFIG  SKIP    complex Host line: %s\n' "$content"
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        fi

        for ((drop_index=0; drop_index<${#__kh_clean_cfg_drop_tokens[@]}; drop_index++)); do
            printf 'CONFIG  REMOVE  %-32s -> %-35s %s\n' \
                "${__kh_clean_cfg_drop_tokens[$drop_index]}" \
                "${__kh_clean_cfg_drop_lookups[$drop_index]}" \
                "${__kh_clean_cfg_drop_reasons[$drop_index]}"
        done

        ((changes+=${#__kh_clean_cfg_drop_tokens[@]}))

        if ((${#__kh_clean_cfg_keep_tokens[@]} == 0)); then
            # Gesamten Host-Block entfernen, nicht nur die Direktiven. Dadurch
            # bleiben auch auskommentierte blockbezogene Optionen wie
            # #IdentityFile oder #RemoteCommand nicht verwaist zurueck.
            block_end=${#lines[@]}
            for ((j=i+1; j<${#lines[@]}; j++)); do
                code=${lines[$j]%%#*}
                content=$code
                content=${content#"${content%%[![:space:]]*}"}
                header_keyword=${content%%[[:space:]=]*}
                header_keyword=${header_keyword,,}
                if [[ $header_keyword == host || $header_keyword == match ]]; then
                    block_end=$j
                    break
                fi
            done

            i=$((block_end - 1))
            continue
        fi

        # Mehrere konkrete Aliase in einer Host-Zeile: nur die veralteten
        # Aliase entfernen und den Block fuer die verbleibenden behalten.
        indent=${line%%[![:space:]]*}
        comment=''
        [[ $line == *'#'* ]] && comment=${line#*#}

        printf '%sHost' "$indent" >> "$tmp" || return 1
        for content in "${__kh_clean_cfg_keep_tokens[@]}"; do
            printf ' %s' "$content" >> "$tmp" || return 1
        done
        if [[ $line == *'#'* ]]; then
            printf ' #%s' "$comment" >> "$tmp" || return 1
        fi
        printf '\n' >> "$tmp" || return 1
    done

    __kh_clean_config_changes=$changes
    return 0
}

__kh_clean_usage() {
    cat <<'EOF_USAGE'
Aufruf: known-hosts-clean [--apply]

Prueft nicht gehashte known_hosts-Eintraege mit ssh-keyscan und entfernt
passende veraltete Host-Aliase aus der primaeren SSH-Konfiguration.
Ohne --apply wird nur angezeigt, was entfernt wuerde.
Mit --apply werden vor Aenderungen Backups angelegt.

Ein Config-Alias wird entfernt, wenn sein aufgeloestes known_hosts-Ziel nach
der Key-Pruefung veraltet ist. Gibt es fuer den Alias keinen pruefbaren
known_hosts-Eintrag, wird HostName/Port direkt mit ssh-keyscan geprueft und ein
nicht erreichbares Ziel ebenfalls entfernt. Komplexe Host-Muster und
Include-Dateien werden nicht automatisch geaendert.

Umgebungsvariablen:
  SSH_KNOWN_HOSTS_FILE           Pfad zu known_hosts
  SSH_CONFIG_FILE                Primaere SSH-Konfiguration
  SSH_KNOWN_HOSTS_CLEAN_TIMEOUT  ssh-keyscan Timeout in Sekunden (Standard: 3)
EOF_USAGE
}

ssh_known_hosts_clean() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local timeout=${SSH_KNOWN_HOSTS_CLEAN_TIMEOUT:-3}
    local apply=0
    local tmp_known='' tmp_config=''
    local backup_known='' backup_config='' stamp
    local line hosts keytype stored_key rest host port result keep_rc
    local rc=0 known_changes=0 config_changes=0
    local config_exists=0

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

    if [[ -e $config ]]; then
        [[ -f $config && -r $config ]] || {
            printf 'known-hosts-clean: SSH-Konfiguration nicht lesbar: %s\n' "$config" >&2
            return 1
        }
        config_exists=1
    fi

    if (( apply )); then
        [[ -w $known_hosts_file ]] || {
            printf 'known-hosts-clean: known_hosts ist nicht beschreibbar: %s\n' \
                "$known_hosts_file" >&2
            return 1
        }
        if (( config_exists )) && [[ ! -w $config ]]; then
            printf 'known-hosts-clean: SSH-Konfiguration ist nicht beschreibbar: %s\n' \
                "$config" >&2
            return 1
        fi
    fi

    command -v ssh-keyscan >/dev/null 2>&1 || {
        printf 'known-hosts-clean: ssh-keyscan wurde nicht gefunden.\n' >&2
        return 1
    }
    command -v ssh >/dev/null 2>&1 || {
        printf 'known-hosts-clean: ssh wurde nicht gefunden.\n' >&2
        return 1
    }
    command -v awk >/dev/null 2>&1 || {
        printf 'known-hosts-clean: awk wurde nicht gefunden.\n' >&2
        return 1
    }

    tmp_known=$(mktemp) || {
        printf 'known-hosts-clean: temporaere Datei konnte nicht angelegt werden.\n' >&2
        return 1
    }
    if (( config_exists )); then
        tmp_config=$(mktemp) || {
            rm -f -- "$tmp_known"
            printf 'known-hosts-clean: temporaere Config-Datei konnte nicht angelegt werden.\n' >&2
            return 1
        }
    fi

    __kh_clean_reset_state

    # Prospektive known_hosts-Datei immer ohne zu entfernende Eintraege bauen.
    # Im Dry-Run wird sie lediglich nicht zurueckgeschrieben.
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}

        if [[ $line =~ ^[[:space:]]*(#|$) ]]; then
            printf '%s\n' "$line" >> "$tmp_known" || { rc=1; break; }
            continue
        fi

        if [[ $line == @* ]]; then
            local marker_hosts marker_keytype marker_key marker_rest marker_name
            read -r marker_name marker_hosts marker_keytype marker_key marker_rest <<< "$line"
            printf '%s\n' 'SKIP    marker entry'

            # Ein einfacher Marker-Eintrag fuer dasselbe Lookup-Ziel wird bewusst
            # behalten und verhindert daher das automatische Entfernen der Config.
            if [[ -n $marker_hosts && $marker_hosts != '|1|'* &&
                  $marker_hosts != *','* && $marker_hosts != *'*'* &&
                  $marker_hosts != *'?'* && $marker_hosts != *'!'* ]]; then
                __kh_clean_target_keep["$marker_hosts"]=1
            fi

            __kh_clean_keep_line "$line" "$tmp_known"
            keep_rc=$?
            (( keep_rc == 10 )) && ((known_changes+=1))
            (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
            continue
        fi

        read -r hosts keytype stored_key rest <<< "$line"

        if [[ $hosts == '|1|'* ]]; then
            printf '%s\n' 'SKIP    hashed entry'
            __kh_clean_keep_line "$line" "$tmp_known"
            keep_rc=$?
            (( keep_rc == 10 )) && ((known_changes+=1))
            (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
            continue
        fi

        if [[ $hosts == *','* ||
              $hosts == *'*'* ||
              $hosts == *'?'* ||
              $hosts == *'!'* ]]; then
            printf 'SKIP    complex host: %s\n' "$hosts"
            __kh_clean_keep_line "$line" "$tmp_known"
            keep_rc=$?
            (( keep_rc == 10 )) && ((known_changes+=1))
            (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
            continue
        fi

        host=$hosts
        port=22

        if [[ $hosts =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[2]}
        fi

        printf 'CHECK   %-35s %-28s ' "$host:$port" "$keytype"

        __kh_clean_check_entry "$host" "$port" "$keytype" "$stored_key" "$timeout"
        result=$?
        __kh_clean_record_target_result "$hosts" "$result"

        case $result in
            0)
                printf '%s\n' 'OK'
                __kh_clean_keep_line "$line" "$tmp_known"
                keep_rc=$?
                (( keep_rc == 10 )) && ((known_changes+=1))
                (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
                ;;
            1)
                printf '%s\n' 'KEY MISMATCH -> REMOVE'
                ((known_changes+=1))
                ;;
            2)
                printf '%s\n' 'UNREACHABLE -> REMOVE'
                ((known_changes+=1))
                ;;
            3)
                printf '%s\n' 'UNSUPPORTED KEY TYPE -> KEEP'
                __kh_clean_keep_line "$line" "$tmp_known"
                keep_rc=$?
                (( keep_rc == 10 )) && ((known_changes+=1))
                (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
                ;;
        esac
    done < "$known_hosts_file"

    if (( rc == 0 )); then
        __kh_clean_finalize_targets

        if (( config_exists )); then
            printf '\nSSH-Konfiguration pruefen: %s\n' "$config"
            __kh_clean_build_config "$config" "$tmp_config" "$timeout" || rc=1
            config_changes=$__kh_clean_config_changes
        fi
    fi

    if (( rc != 0 )); then
        rm -f -- "$tmp_known" "$tmp_config"
        printf 'known-hosts-clean: temporaere Ausgabe konnte nicht geschrieben werden.\n' >&2
        return "$rc"
    fi

    if (( apply )); then
        stamp=$(date +%Y%m%d-%H%M%S)

        if (( known_changes > 0 )); then
            backup_known="${known_hosts_file}.bak.$stamp"
            if ! command cp -- "$known_hosts_file" "$backup_known"; then
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts-clean: known_hosts-Backup konnte nicht angelegt werden.\n' >&2
                return 1
            fi
        fi

        if (( config_changes > 0 )); then
            backup_config="${config}.bak.$stamp"
            if ! command cp -- "$config" "$backup_config"; then
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts-clean: Config-Backup konnte nicht angelegt werden.\n' >&2
                return 1
            fi
        fi

        if (( known_changes > 0 )); then
            if ! command cat -- "$tmp_known" > "$known_hosts_file"; then
                [[ -n $backup_known ]] && command cp -- "$backup_known" "$known_hosts_file" 2>/dev/null || true
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts-clean: known_hosts konnte nicht geschrieben werden; Backup wurde wiederhergestellt.\n' >&2
                return 1
            fi
        fi

        if (( config_changes > 0 )); then
            if ! command cat -- "$tmp_config" > "$config"; then
                [[ -n $backup_known ]] && command cp -- "$backup_known" "$known_hosts_file" 2>/dev/null || true
                [[ -n $backup_config ]] && command cp -- "$backup_config" "$config" 2>/dev/null || true
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts-clean: SSH-Konfiguration konnte nicht geschrieben werden; Backups wurden wiederhergestellt.\n' >&2
                return 1
            fi
        fi

        rm -f -- "$tmp_known" "$tmp_config"

        if (( known_changes > 0 || config_changes > 0 )); then
            declare -F __kh_cache_invalidate >/dev/null && __kh_cache_invalidate
            declare -F __ssh_completion_cache_invalidate >/dev/null && __ssh_completion_cache_invalidate
            declare -F __ssh_resolve_ips_cache_invalidate >/dev/null && __ssh_resolve_ips_cache_invalidate
        fi

        printf '\nBereinigung abgeschlossen.\n'
        printf 'known_hosts: %d Aenderung(en)\n' "$known_changes"
        printf 'SSH config:  %d Alias-Aenderung(en)\n' "$config_changes"
        [[ -z $backup_known ]] || printf 'Backup known_hosts: %s\n' "$backup_known"
        [[ -z $backup_config ]] || printf 'Backup SSH config:  %s\n' "$backup_config"
    else
        rm -f -- "$tmp_known" "$tmp_config"
        printf '\nDRY RUN - es wurden keine Dateien veraendert.\n'
        printf 'known_hosts: %d Aenderung(en) wuerden vorgenommen\n' "$known_changes"
        printf 'SSH config:  %d Alias-Aenderung(en) wuerden vorgenommen\n\n' "$config_changes"
        printf 'Zum tatsaechlichen Bereinigen:\n'
        printf '  known-hosts-clean --apply\n'
    fi

    return 0
}
