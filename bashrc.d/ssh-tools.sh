#!/usr/bin/env bash

# Bash 4+: Cache gilt fuer diese Shell. Nach Konfigurationsaenderungen --refresh.
declare -A __kh_rows=()
__kh_cache_id=''
__kh_known_content=''

# Sammelt konkrete Host-Aliase. Keine Shell-Auswertung der Konfigurationsdaten.
# Include: relative Pfade unter ~/.ssh, absolute Pfade, ~/, Globs.
# Tokens wie %h in Include-Pfaden und Pfade mit Leerzeichen werden ausgelassen.
__kh_discover() {
    local file=$1 base=$2 line keyword token match
    local -a words

    [[ -r $file && -z ${visited["$file"]+x} ]] || return 0
    visited["$file"]=1

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line%%#*}
        line=${line/=/ }
        read -r -a words <<< "$line"
        ((${#words[@]})) || continue

        keyword=${words[0],,}
        for token in "${words[@]:1}"; do
            token=${token#\"}
            token=${token%\"}

            case $keyword in
                host)
                    [[ -n $token && $token != -* &&
                       $token != *['*?!']* &&
                       $token != *[[:space:][:cntrl:]]* ]] || continue

                    if [[ -z ${candidates["$token"]+x} ]]; then
                        candidates["$token"]=1
                        candidate_order+=("$token")
                    fi
                    ;;

                include)
                    [[ $token != *['%$']* ]] || continue
                    case $token in
                        '~/'*) token="$HOME/${token:2}" ;;
                        /*) ;;
                        *) token="$base/$token" ;;
                    esac

                    while IFS= read -r match; do
                        [[ -z $match ]] || __kh_discover "$match" "$base"
                    done <<< "$(compgen -G "$token" || true)"
                    ;;
            esac
        done
    done < "$file"
}

__kh_refresh() {
    local known=$1 config=$2 alias resolved field value host user port keyalias lookup hits n rc
    local row_token
    local -A candidates=() visited=() row_seen=()
    local -a candidate_order=()

    __kh_cache_id=''
    __kh_rows=()

    __kh_discover "$config" "$HOME/.ssh"
    __kh_discover /etc/ssh/ssh_config /etc/ssh

    for alias in "${candidate_order[@]}"; do
        # -G oeffnet keine SSH-Sitzung. Konfigurierte Match-exec-Regeln koennen laufen.
        if [[ $config == "$HOME/.ssh/config" ]]; then
            resolved=$(command ssh -G -T "$alias") || {
                printf 'known-hosts: SSH-Konfiguration fuer Alias %q konnte nicht ausgewertet werden.\n' "$alias" >&2
                return 1
            }
        else
            resolved=$(command ssh -G -T -F "$config" "$alias") || {
                printf 'known-hosts: SSH-Konfiguration fuer Alias %q konnte nicht ausgewertet werden.\n' "$alias" >&2
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
                __kh_rows[$n]+="$alias"$'\t'"$user"$'\t'"$lookup"$'\n'
            fi
        done <<< "$hits"
    done

    __kh_cache_id="$known|$config"
    __kh_known_content=$(< "$known")
}

# Standardansicht nach Cache-Aufbau ohne externe Prozesse.
# Pro Alias/Ziel/Benutzer wird genau eine Zeile ausgegeben.
# Mehrere known_hosts-Zeilen und Schluesseltypen werden zusammengefasst.
ssh_known_hosts() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local filter=${1-}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}

    local line line_number=0 first second third fourth remainder
    local marker hosts key_type key display_hosts target
    local rows alias user lookup search filter_lc
    local group_key seen_token gid group_count=0 i
    local sep=$'\x1f'
    local found=0

    local -A group_id=() key_seen=() line_seen=()
    local -a agg_alias=() agg_target=() agg_user=() agg_lines=() agg_keys=()
    local -a selected_ids=()

    # ZIEL und ALIAS verwenden bewusst dieselbe Breite.
    # Die gemeinsame Breite richtet sich nach dem laengsten Wert beider Spalten.
    local w_line=5 w_target=4 w_alias=5 w_host=5 w_user=8

    if (( $# > 1 )); then
        printf 'Aufruf: known-hosts [FILTER | --refresh | --fingerprints]\n' >&2
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

    if [[ $filter == --refresh ]]; then
        __kh_cache_id=''
        filter=''
    fi

    if [[ $__kh_cache_id != "$known_hosts_file|$config" ||
          $__kh_known_content != "$(< "$known_hosts_file")" ]]; then
        __kh_refresh "$known_hosts_file" "$config" || return
    fi

    # Erst alle known_hosts-Eintraege einlesen und gruppieren.
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
            # Jeder explizite SSH-Alias bleibt eine eigene Gruppe/Zeile.
            while IFS=$'\t' read -r alias user lookup; do
                [[ -n $alias ]] || continue

                target=$lookup
                [[ -z $marker || $target == "$marker "* ]] || target="$marker $target"

                group_key="A$sep$alias$sep$target$sep$user"
                if [[ -z ${group_id["$group_key"]+x} ]]; then
                    gid=$group_count
                    ((group_count+=1))
                    group_id["$group_key"]=$gid
                    agg_alias[$gid]=$alias
                    agg_target[$gid]=$target
                    agg_user[$gid]=$user
                    agg_lines[$gid]=''
                    agg_keys[$gid]=''
                else
                    gid=${group_id["$group_key"]}
                fi

                seen_token="$gid$sep$line_number"
                if [[ -z ${line_seen["$seen_token"]+x} ]]; then
                    line_seen["$seen_token"]=1
                    if [[ -n ${agg_lines[$gid]} ]]; then
                        agg_lines[$gid]+=",$line_number"
                    else
                        agg_lines[$gid]=$line_number
                    fi
                fi

                seen_token="$gid$sep$key_type"
                if [[ -z ${key_seen["$seen_token"]+x} ]]; then
                    key_seen["$seen_token"]=1
                    if [[ -n ${agg_keys[$gid]} ]]; then
                        agg_keys[$gid]+=", $key_type"
                    else
                        agg_keys[$gid]=$key_type
                    fi
                fi
            done <<< "$rows"
        else
            # Nicht durch ~/.ssh/config aufloesbare Eintraege ebenfalls
            # zusammenfassen. Fuer gehashte Hosts dient der echte Hash als
            # Gruppenschluessel, damit verschiedene unbekannte Hosts nicht
            # versehentlich zusammenfallen.
            alias='—'
            user='—'
            target=$display_hosts
            group_key="U$sep$marker$sep$hosts"

            if [[ -z ${group_id["$group_key"]+x} ]]; then
                gid=$group_count
                ((group_count+=1))
                group_id["$group_key"]=$gid
                agg_alias[$gid]=$alias
                agg_target[$gid]=$target
                agg_user[$gid]=$user
                agg_lines[$gid]=''
                agg_keys[$gid]=''
            else
                gid=${group_id["$group_key"]}
            fi

            seen_token="$gid$sep$line_number"
            if [[ -z ${line_seen["$seen_token"]+x} ]]; then
                line_seen["$seen_token"]=1
                if [[ -n ${agg_lines[$gid]} ]]; then
                    agg_lines[$gid]+=",$line_number"
                else
                    agg_lines[$gid]=$line_number
                fi
            fi

            seen_token="$gid$sep$key_type"
            if [[ -z ${key_seen["$seen_token"]+x} ]]; then
                key_seen["$seen_token"]=1
                if [[ -n ${agg_keys[$gid]} ]]; then
                    agg_keys[$gid]+=", $key_type"
                else
                    agg_keys[$gid]=$key_type
                fi
            fi
        fi
    done < "$known_hosts_file"

    filter_lc=${filter,,}

    # Filtern und gleichzeitig die benoetigten Spaltenbreiten bestimmen.
    for ((i=0; i<group_count; i++)); do
        search="${agg_alias[$i]} ${agg_target[$i]} ${agg_user[$i]} ${agg_keys[$i]} ${agg_lines[$i]}"
        [[ -z $filter || ${search,,} == *"$filter_lc"* ]] || continue

        selected_ids+=("$i")
        found=1

        ((${#agg_lines[$i]}  > w_line))   && w_line=${#agg_lines[$i]}
        ((${#agg_alias[$i]}  > w_alias))  && w_alias=${#agg_alias[$i]}
        ((${#agg_target[$i]} > w_target)) && w_target=${#agg_target[$i]}
        ((${#agg_user[$i]}   > w_user))   && w_user=${#agg_user[$i]}
    done

    # ZIEL und ALIAS exakt gleich breit formatieren.
    w_host=$w_target
    ((w_alias > w_host)) && w_host=$w_alias

    printf '\e[2m%-*s  %-*s  %-*s  %-*s  %s\e[0m\n' \
        "$w_line" 'ZEILE' \
        "$w_host" 'ZIEL' \
        "$w_host" 'ALIAS' \
        "$w_user" 'BENUTZER' \
        'SCHLÜSSEL'

    if (( ! found )); then
        if [[ -n $filter ]]; then
            printf 'Keine lesbaren Einträge für „%s“ gefunden.\n' "$filter"
        else
            printf 'Keine Einträge gefunden.\n'
        fi
        return 0
    fi

    for gid in "${selected_ids[@]}"; do
        printf '%-*s  \e[36m%-*s  %-*s\e[0m  %-*s  \e[33m%s\e[0m\n' \
            "$w_line" "${agg_lines[$gid]}" \
            "$w_host" "${agg_target[$gid]}" \
            "$w_host" "${agg_alias[$gid]}" \
            "$w_user" "${agg_user[$gid]}" \
            "${agg_keys[$gid]}"
    done

    return 0
}

unalias known-hosts ssh-known-hosts 2>/dev/null || true
alias known-hosts='ssh_known_hosts'
alias ssh-known-hosts='ssh_known_hosts'
