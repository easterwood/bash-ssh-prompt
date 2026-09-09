#!/usr/bin/env bash

# Host-Zuordnungscache fuer diese Shell.
declare -A __kh_rows=()
# Effektiver Benutzer fuer direkte known_hosts-Ziele ohne zugeordneten Alias.
declare -A __kh_target_users=()
# 1, wenn der Benutzer direkt in einem konkreten Host-Block der Benutzer-Config steht.
declare -A __kh_target_user_explicit=()
__kh_cache_id=''
__kh_known_content=''

__kh_cache_invalidate() {
    __kh_cache_id=''
    __kh_rows=()
    __kh_target_users=()
    __kh_target_user_explicit=()
    declare -F __kh_groups_reset >/dev/null && __kh_groups_reset
}

__kh_refresh() {
    local known=$1 config=$2
    local alias resolved field value host user port keyalias lookup hits n rc row_token user_explicit
    local -A row_seen=()

    __kh_cache_invalidate
    __kh_scan_configs "$config" 0

    for alias in "${__kh_scan_aliases[@]}"; do
        # -G oeffnet keine SSH-Sitzung. Konfigurierte Match-exec-Regeln koennen laufen.
        if [[ $config == "$HOME/.ssh/config" ]]; then
            resolved=$(command ssh -G -T "$alias") || {
                printf 'known-hosts: SSH-Konfiguration für Alias %q konnte nicht ausgewertet werden.\n' "$alias" >&2
                return 1
            }
        else
            resolved=$(command ssh -G -T -F "$config" "$alias") || {
                printf 'known-hosts: SSH-Konfiguration für Alias %q konnte nicht ausgewertet werden.\n' "$alias" >&2
                return 1
            }
        fi

        host=''
        user=''
        port=22
        keyalias=''

        while read -r field value; do
            case $field in
                hostname) host=$value ;;
                user) user=$value ;;
                port) port=$value ;;
                hostkeyalias) keyalias=$value ;;
            esac
        done <<< "$resolved"

        [[ -n $host && -n $user ]] || continue

        lookup=$host
        [[ -z $keyalias || $keyalias == none ]] || lookup=$keyalias
        [[ $port == 22 ]] || lookup="[$lookup]:$port"

        rc=0
        hits=$(command ssh-keygen -F "$lookup" -f "$known") || rc=$?
        ((rc <= 1)) || return "$rc"

        while IFS= read -r value; do
            if [[ $value =~ ^#[[:space:]].*[[:space:]]line[[:space:]]([0-9]+)[[:space:]]*$ ]]; then
                n=${BASH_REMATCH[1]}
                row_token="$n"$'\x1f'"$alias"$'\x1f'"$user"$'\x1f'"$lookup"
                [[ -z ${row_seen["$row_token"]+x} ]] || continue
                row_seen["$row_token"]=1
                user_explicit=0
                if [[ ${__kh_scan_alias_direct_user["$alias"]-} == "$user" ]]; then
                    user_explicit=1
                fi
                __kh_rows[$n]+="$alias"$'\t'"$user"$'\t'"$lookup"$'\t'"$user_explicit"$'\n'
            fi
        done <<< "$hits"
    done

    # Fuer known_hosts-Eintraege ohne explizite Alias-Zuordnung trotzdem den
    # effektiven Benutzer aus der SSH-Konfiguration bestimmen. Dadurch greifen
    # auch Host *-Defaults und Host-Wildcards. Der Zielhost wird dabei nicht als
    # Alias ausgegeben.
    local kh_line kh_line_number=0 first second raw_hosts raw_host effective_user
    while IFS= read -r kh_line || [[ -n $kh_line ]]; do
        ((kh_line_number+=1))
        [[ $kh_line =~ ^[[:space:]]*(#|$) ]] && continue

        read -r first second _ <<< "$kh_line"
        if [[ $first == @* ]]; then
            raw_hosts=$second
        else
            raw_hosts=$first
        fi

        [[ -n $raw_hosts ]] || continue
        [[ -z ${__kh_rows[$kh_line_number]-} ]] || continue
        [[ $raw_hosts != '|1|'* ]] || continue
        [[ $raw_hosts != *','* &&
           $raw_hosts != *'*'* &&
           $raw_hosts != *'?'* &&
           $raw_hosts != *'!'* ]] || continue
        [[ -z ${__kh_target_users["$raw_hosts"]+x} ]] || continue

        raw_host=$raw_hosts
        if [[ $raw_hosts =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
            raw_host=${BASH_REMATCH[1]}
        fi

        resolved=''
        if [[ $config == "$HOME/.ssh/config" ]]; then
            resolved=$(command ssh -G -T "$raw_host" 2>/dev/null) || true
        else
            resolved=$(command ssh -G -T -F "$config" "$raw_host" 2>/dev/null) || true
        fi

        effective_user=''
        while read -r field value; do
            [[ $field == user ]] || continue
            effective_user=$value
            break
        done <<< "$resolved"

        __kh_target_users["$raw_hosts"]=${effective_user:--}
        __kh_target_user_explicit["$raw_hosts"]=0

        # Nicht markieren, wenn genau der effektive Benutzer explizit einem
        # konkreten Host/Alias oder dessen literalem HostName zugeordnet ist.
        # Ein User aus "Host *" oder Wildcard-Bloecken bleibt dagegen geerbt.
        if [[ -n $effective_user &&
              ( ${__kh_scan_alias_direct_user["$raw_host"]-} == "$effective_user" ||
                ${__kh_scan_target_direct_user["$raw_host"]-} == "$effective_user" ) ]]; then
            __kh_target_user_explicit["$raw_hosts"]=1
        fi
    done < "$known"

    __kh_cache_id="$known|$config"
    __kh_known_content=$(< "$known")
}

__kh_cache_ensure() {
    local known=$1 config=$2

    if [[ $__kh_cache_id != "$known|$config" ||
          $__kh_known_content != "$(< "$known")" ]]; then
        __kh_refresh "$known" "$config"
    fi
}

# Gemeinsames, aggregiertes Modell fuer Anzeige und Login per Zielnummer.
declare -a __kh_group_alias=()
declare -a __kh_group_target=()
declare -a __kh_group_user=()
declare -a __kh_group_user_explicit=()
declare -a __kh_group_lines=()
declare -a __kh_group_keys=()
__kh_group_count=0

__kh_groups_reset() {
    __kh_group_alias=()
    __kh_group_target=()
    __kh_group_user=()
    __kh_group_user_explicit=()
    __kh_group_lines=()
    __kh_group_keys=()
    __kh_group_count=0
}

# Baut genau dieselben Gruppen auf, die known-hosts anzeigt. Die Gruppenreihenfolge
# definiert zugleich die stabile Zielnummer innerhalb des aktuellen Dateistands.
__kh_groups_build() {
    local known_hosts_file=$1 config=$2
    local line line_number=0 first second third fourth remainder
    local marker hosts key_type key display_hosts target
    local rows alias user lookup user_explicit
    local group_key seen_token gid
    local sep=$'\x1f'
    local -A group_id=() key_seen=() line_seen=()

    __kh_groups_reset
    __kh_cache_ensure "$known_hosts_file" "$config" || return

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

        key_type=${key_type#ssh-}
        key_type=${key_type^^}
        rows=${__kh_rows[$line_number]-}

        if [[ -n $rows ]]; then
            while IFS=$'\t' read -r alias user lookup user_explicit; do
                [[ -n $alias ]] || continue

                target=$lookup
                [[ -z $marker || $target == "$marker "* ]] || target="$marker $target"

                group_key="A$sep$alias$sep$target$sep$user"
                if [[ -z ${group_id["$group_key"]+x} ]]; then
                    gid=$__kh_group_count
                    ((__kh_group_count+=1))
                    group_id["$group_key"]=$gid
                    __kh_group_alias[$gid]=$alias
                    __kh_group_target[$gid]=$target
                    __kh_group_user[$gid]=$user
                    __kh_group_user_explicit[$gid]=${user_explicit:-0}
                    __kh_group_lines[$gid]=''
                    __kh_group_keys[$gid]=''
                else
                    gid=${group_id["$group_key"]}
                fi

                seen_token="$gid$sep$line_number"
                if [[ -z ${line_seen["$seen_token"]+x} ]]; then
                    line_seen["$seen_token"]=1
                    if [[ -n ${__kh_group_lines[$gid]} ]]; then
                        __kh_group_lines[$gid]+=",$line_number"
                    else
                        __kh_group_lines[$gid]=$line_number
                    fi
                fi

                seen_token="$gid$sep$key_type"
                if [[ -z ${key_seen["$seen_token"]+x} ]]; then
                    key_seen["$seen_token"]=1
                    if [[ -n ${__kh_group_keys[$gid]} ]]; then
                        __kh_group_keys[$gid]+=", $key_type"
                    else
                        __kh_group_keys[$gid]=$key_type
                    fi
                fi
            done <<< "$rows"
        else
            alias='-'
            user=${__kh_target_users["$hosts"]:--}
            user_explicit=${__kh_target_user_explicit["$hosts"]:-0}
            target=$display_hosts
            group_key="U$sep$marker$sep$hosts"

            if [[ -z ${group_id["$group_key"]+x} ]]; then
                gid=$__kh_group_count
                ((__kh_group_count+=1))
                group_id["$group_key"]=$gid
                __kh_group_alias[$gid]=$alias
                __kh_group_target[$gid]=$target
                __kh_group_user[$gid]=$user
                __kh_group_user_explicit[$gid]=${user_explicit:-0}
                __kh_group_lines[$gid]=''
                __kh_group_keys[$gid]=''
            else
                gid=${group_id["$group_key"]}
            fi

            seen_token="$gid$sep$line_number"
            if [[ -z ${line_seen["$seen_token"]+x} ]]; then
                line_seen["$seen_token"]=1
                if [[ -n ${__kh_group_lines[$gid]} ]]; then
                    __kh_group_lines[$gid]+=",$line_number"
                else
                    __kh_group_lines[$gid]=$line_number
                fi
            fi

            seen_token="$gid$sep$key_type"
            if [[ -z ${key_seen["$seen_token"]+x} ]]; then
                key_seen["$seen_token"]=1
                if [[ -n ${__kh_group_keys[$gid]} ]]; then
                    __kh_group_keys[$gid]+=", $key_type"
                else
                    __kh_group_keys[$gid]=$key_type
                fi
            fi
        fi
    done < "$known_hosts_file"
}

# Pro Alias/Ziel/Benutzer wird genau eine Zeile ausgegeben.
# Mehrere known_hosts-Zeilen und Schluesseltypen werden zusammengefasst.
# NR ist die eindeutige Zielnummer fuer ssh-nr.
ssh_known_hosts() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local filter=''
    local show_lines=0 refresh=0 fingerprints=0
    local arg search filter_lc gid nr found=0
    local -a selected_ids=()
    local w_nr=2 w_line=5 w_target=4 w_alias=5 w_host=5 w_user=8

    while (( $# )); do
        arg=$1
        shift

        case $arg in
            --lines|--zeilen)
                show_lines=1
                ;;
            --refresh)
                refresh=1
                ;;
            --fingerprints)
                fingerprints=1
                ;;
            --help|-h)
                printf 'Aufruf: known-hosts [--lines] [--refresh] [FILTER]\n'
                printf '        known-hosts --fingerprints\n'
                printf '\n'
                printf '  --lines, --zeilen  known_hosts-Zeilennummern einblenden\n'
                printf '  --refresh          Cache verwerfen und Daten neu einlesen\n'
                printf '  --fingerprints     Original-Fingerprints mit ssh-keygen anzeigen\n'
                return 0
                ;;
            --)
                if (( $# > 1 )); then
                    printf 'known-hosts: Es ist nur ein FILTER erlaubt.\n' >&2
                    return 2
                fi
                if (( $# == 1 )); then
                    [[ -z $filter ]] || {
                        printf 'known-hosts: Es ist nur ein FILTER erlaubt.\n' >&2
                        return 2
                    }
                    filter=$1
                    shift
                fi
                ;;
            -*)
                printf 'known-hosts: unbekannte Option: %s\n' "$arg" >&2
                printf 'Aufruf: known-hosts [--lines] [--refresh] [FILTER]\n' >&2
                return 2
                ;;
            *)
                if [[ -n $filter ]]; then
                    printf 'known-hosts: Es ist nur ein FILTER erlaubt.\n' >&2
                    return 2
                fi
                filter=$arg
                ;;
        esac
    done

    [[ -r $known_hosts_file ]] || {
        printf 'known-hosts: %s fehlt oder ist nicht lesbar.\n' "$known_hosts_file" >&2
        return 1
    }

    if (( fingerprints )); then
        if (( show_lines || refresh )) || [[ -n $filter ]]; then
            printf 'known-hosts: --fingerprints kann nicht mit FILTER, --lines oder --refresh kombiniert werden.\n' >&2
            return 2
        fi
        ssh-keygen -l -E sha256 -f "$known_hosts_file"
        return $?
    fi

    if (( refresh )); then
        __kh_cache_invalidate
        __kh_groups_reset
        __ssh_completion_cache_invalidate
        declare -F __ssh_resolve_ips_cache_invalidate >/dev/null && __ssh_resolve_ips_cache_invalidate
        declare -F __ssh_resolve_hosts_cache_invalidate >/dev/null && __ssh_resolve_hosts_cache_invalidate
    fi

    __kh_groups_build "$known_hosts_file" "$config" || return
    filter_lc=${filter,,}

    for ((gid=0; gid<__kh_group_count; gid++)); do
        nr=$((gid + 1))
        search="$nr ${__kh_group_alias[$gid]} ${__kh_group_target[$gid]} ${__kh_group_user[$gid]} ${__kh_group_keys[$gid]} ${__kh_group_lines[$gid]}"
        [[ -z $filter || ${search,,} == *"$filter_lc"* ]] || continue

        selected_ids+=("$gid")
        found=1

        ((${#nr} > w_nr)) && w_nr=${#nr}
        if (( show_lines )); then
            ((${#__kh_group_lines[$gid]} > w_line)) && w_line=${#__kh_group_lines[$gid]}
        fi
        ((${#__kh_group_alias[$gid]}  > w_alias))  && w_alias=${#__kh_group_alias[$gid]}
        ((${#__kh_group_target[$gid]} > w_target)) && w_target=${#__kh_group_target[$gid]}
        ((${#__kh_group_user[$gid]}   > w_user))   && w_user=${#__kh_group_user[$gid]}
    done

    w_host=$w_target
    ((w_alias > w_host)) && w_host=$w_alias

    if (( show_lines )); then
        printf '\e[2m%-*s  %-*s  %-*s  %-*s  %-*s  %s\e[0m\n' \
            "$w_nr" 'NR' \
            "$w_line" 'ZEILE' \
            "$w_host" 'ZIEL' \
            "$w_host" 'ALIAS' \
            "$w_user" 'BENUTZER' \
            'SCHLÜSSEL'
    else
        printf '\e[2m%-*s  %-*s  %-*s  %-*s  %s\e[0m\n' \
            "$w_nr" 'NR' \
            "$w_host" 'ZIEL' \
            "$w_host" 'ALIAS' \
            "$w_user" 'BENUTZER' \
            'SCHLÜSSEL'
    fi

    if (( ! found )); then
        if [[ -n $filter ]]; then
            printf 'Keine lesbaren Einträge für "%s" gefunden.\n' "$filter"
        else
            printf 'Keine Einträge gefunden.\n'
        fi
        return 0
    fi

    for gid in "${selected_ids[@]}"; do
        nr=$((gid + 1))

        if (( show_lines )); then
            printf '%-*s  %-*s  \e[36m%-*s  %-*s\e[0m  ' \
                "$w_nr" "$nr" \
                "$w_line" "${__kh_group_lines[$gid]}" \
                "$w_host" "${__kh_group_target[$gid]}" \
                "$w_host" "${__kh_group_alias[$gid]}"
        else
            printf '%-*s  \e[36m%-*s  %-*s\e[0m  ' \
                "$w_nr" "$nr" \
                "$w_host" "${__kh_group_target[$gid]}" \
                "$w_host" "${__kh_group_alias[$gid]}"
        fi

        if [[ ${__kh_group_user[$gid]} != '-' && ${__kh_group_user_explicit[$gid]:-0} != 1 ]]; then
            printf '\e[35m%-*s\e[0m' "$w_user" "${__kh_group_user[$gid]}"
        else
            printf '%-*s' "$w_user" "${__kh_group_user[$gid]}"
        fi

        printf '  \e[33m%s\e[0m\n' "${__kh_group_keys[$gid]}"
    done

    return 0
}
