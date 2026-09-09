#!/usr/bin/env bash

# Gegenstueck zu ssh-resolve-ips: zeigt zu jedem Hostnamen aus SSH-Config und
# known_hosts die zugehoerigen IP-Adressen.
#
# Diese Datei setzt lib/ssh-resolve-ips.sh voraus und nutzt daraus die
# IP-Erkennung, den Timeout-Wrapper und die Pfaddarstellung. Die Reihenfolge
# der source-Zeilen in bashrc.d/ssh-tools.sh ist deshalb relevant.

# Vorwaerts-DNS-Cache fuer diese Shell. --refresh verwirft nur die DNS-
# Ergebnisse; known_hosts und SSH-Config werden bei jedem Aufruf neu gelesen.
declare -A __ssh_resolve_hosts_dns_cache=()

__ssh_resolve_hosts_cache_invalidate() {
    __ssh_resolve_hosts_dns_cache=()
}

# Extrahiert aus einem Host-Token einen aufloesbaren Hostnamen. Unterstuetzt
# auch [host]:Port. IP-Literale und Muster werden bewusst uebersprungen: die
# IP-Seite deckt ssh-resolve-ips ab.
__ssh_resolve_hosts_extract_name() {
    local token=$1 host

    if [[ $token =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
        host=${BASH_REMATCH[1]}
    else
        host=$token
    fi

    [[ -n $host ]] || return 1
    [[ $host != *['*?!']* ]] || return 1
    [[ $host != @* ]] || return 1
    __ssh_resolve_ips_is_ip "$host" && return 1

    printf '%s\n' "${host%.}"
    return 0
}

# Vorwaertsaufloesung mit portablen Backends. Die Ausgabe darf Rohzeilen
# enthalten; der Aufrufer filtert auf gueltige IPs. Fuer Git Bash/Windows ist
# PowerShell der zuverlaessigste Fallback.
__ssh_resolve_hosts_lookup_uncached() {
    local name=$1 timeout_seconds=$2 output='' ps_script=''

    if command -v getent >/dev/null 2>&1; then
        # getent ahosts liefert je Adressfamilie mehrere Zeilen.
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                getent ahosts "$name" 2>/dev/null |
            awk 'NF { print $1 }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "$output"
            return 0
        }
    fi

    if command -v dig >/dev/null 2>&1; then
        output=$(
            {
                __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                    dig +short "$name" A 2>/dev/null
                __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                    dig +short "$name" AAAA 2>/dev/null
            } |
            awk 'NF { print }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "$output"
            return 0
        }
    fi

    if command -v host >/dev/null 2>&1; then
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                host "$name" 2>/dev/null |
            awk '/has (IPv6 )?address/ { print $NF }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "$output"
            return 0
        }
    fi

    if command -v powershell.exe >/dev/null 2>&1; then
        printf -v ps_script \
            "try { [System.Net.Dns]::GetHostAddresses('%s') | ForEach-Object { [Console]::Out.WriteLine(\$_.IPAddressToString) } } catch { exit 1 }" \
            "$name"
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                powershell.exe -NoProfile -NonInteractive -Command "$ps_script" \
                2>/dev/null |
            tr -d '\r' |
            awk 'NF { print }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "$output"
            return 0
        }
    fi

    if command -v nslookup >/dev/null 2>&1; then
        # Die erste Adresse gehoert zum Resolver selbst und wird uebersprungen.
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                nslookup "$name" 2>/dev/null |
            awk '
                /^Name:/ { in_answer=1; next }
                in_answer && /^Address(es)?:/ {
                    value=$0
                    sub(/^Address(es)?:[[:space:]]*/, "", value)
                    print value
                    next
                }
                in_answer && /^[[:space:]]+/ {
                    value=$0
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                    if (value != "") print value
                }
            '
        )
        [[ -z $output ]] || {
            printf '%s\n' "$output"
            return 0
        }
    fi

    return 1
}

__ssh_resolve_hosts_lookup_result=''

# Ergebnis ist eine kommaseparierte Liste, IPv4 vor IPv6.
__ssh_resolve_hosts_lookup() {
    local name=$1 timeout_seconds=$2 cached candidate joined=''
    local ipv4_list='' ipv6_list=''
    local -A seen=()

    __ssh_resolve_hosts_lookup_result=''

    if [[ -n ${__ssh_resolve_hosts_dns_cache["$name"]+x} ]]; then
        cached=${__ssh_resolve_hosts_dns_cache["$name"]}
        [[ $cached != $'\x1e' ]] || return 1
        __ssh_resolve_hosts_lookup_result=$cached
        return 0
    fi

    while IFS= read -r candidate; do
        candidate=${candidate%%[[:space:]]*}
        candidate=${candidate%.}
        [[ -n $candidate ]] || continue
        [[ -z ${seen["$candidate"]+x} ]] || continue

        if __ssh_resolve_ips_is_ipv4 "$candidate"; then
            seen["$candidate"]=1
            if [[ -n $ipv4_list ]]; then
                ipv4_list+=", $candidate"
            else
                ipv4_list=$candidate
            fi
        elif __ssh_resolve_ips_is_ipv6 "$candidate"; then
            seen["$candidate"]=1
            if [[ -n $ipv6_list ]]; then
                ipv6_list+=", $candidate"
            else
                ipv6_list=$candidate
            fi
        fi
    done <<< "$(__ssh_resolve_hosts_lookup_uncached "$name" "$timeout_seconds")"

    joined=$ipv4_list
    if [[ -n $ipv6_list ]]; then
        if [[ -n $joined ]]; then
            joined+=", $ipv6_list"
        else
            joined=$ipv6_list
        fi
    fi

    if [[ -z $joined ]]; then
        # Sentinel fuer eine fehlgeschlagene Aufloesung.
        __ssh_resolve_hosts_dns_cache["$name"]=$'\x1e'
        return 1
    fi

    __ssh_resolve_hosts_dns_cache["$name"]=$joined
    __ssh_resolve_hosts_lookup_result=$joined
    return 0
}

# ssh-resolve-hosts [FILTER | --refresh | --help]
#
# Zeigt jeden gefundenen Hostnamen einmal und fasst Referenzen aus SSH-Config
# und known_hosts zusammen. DNS-Ergebnisse werden innerhalb der Shell gecacht;
# --refresh erzwingt neue Lookups.
ssh_resolve_hosts() {
    local known=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local timeout_seconds=${SSH_RESOLVE_HOST_TIMEOUT:-3}
    local filter=${1-}

    local line line_number first second hosts token name host resolved field value
    local file config_line_number keyword alias ref display_file hostname config_line
    local i search filter_lc
    local -a host_tokens=() words=() current_aliases=() selected=()
    local -A name_seen=() config_ref_seen=() known_line_seen=()
    local -a name_order=()
    local -A config_refs=() known_lines=() addresses=()
    local w_name=8 w_ip=2 w_config=6 w_known=11

    if (( $# > 1 )); then
        printf 'Aufruf: ssh-resolve-hosts [FILTER | --refresh | --help]\n' >&2
        return 2
    fi

    case $filter in
        --help|-h)
            printf 'Aufruf: ssh-resolve-hosts [FILTER | --refresh | --help]\n'
            printf 'Loest Hostnamen aus known_hosts und SSH-Config per DNS zu IPs auf.\n'
            printf 'Gegenstueck zu ssh-resolve-ips, das den umgekehrten Weg geht.\n'
            printf 'Umgebungsvariable: SSH_RESOLVE_HOST_TIMEOUT (Standard: 3 Sekunden).\n'
            return 0
            ;;
        --refresh)
            __ssh_resolve_hosts_cache_invalidate
            filter=''
            ;;
    esac

    [[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
        printf 'ssh-resolve-hosts: ungueltiger Timeout: %s\n' "$timeout_seconds" >&2
        return 2
    }

    declare -F __ssh_resolve_ips_is_ip >/dev/null || {
        printf 'ssh-resolve-hosts: lib/ssh-resolve-ips.sh wurde nicht geladen.\n' >&2
        return 1
    }

    __ssh_resolve_hosts_add_name() {
        local add_name=$1
        [[ -n ${name_seen["$add_name"]+x} ]] || {
            name_seen["$add_name"]=1
            name_order+=("$add_name")
            config_refs["$add_name"]=''
            known_lines["$add_name"]=''
        }
    }

    __ssh_resolve_hosts_add_config_ref() {
        local add_name=$1 add_ref=$2 key
        __ssh_resolve_hosts_add_name "$add_name"
        key="$add_name"$'\x1f'"$add_ref"
        [[ -z ${config_ref_seen["$key"]+x} ]] || return 0
        config_ref_seen["$key"]=1
        if [[ -n ${config_refs["$add_name"]} ]]; then
            config_refs["$add_name"]+=", $add_ref"
        else
            config_refs["$add_name"]=$add_ref
        fi
    }

    __ssh_resolve_hosts_add_known_line() {
        local add_name=$1 add_line=$2 key
        __ssh_resolve_hosts_add_name "$add_name"
        key="$add_name"$'\x1f'"$add_line"
        [[ -z ${known_line_seen["$key"]+x} ]] || return 0
        known_line_seen["$key"]=1
        if [[ -n ${known_lines["$add_name"]} ]]; then
            known_lines["$add_name"]+=",$add_line"
        else
            known_lines["$add_name"]=$add_line
        fi
    }

    # Benutzer-Config und deren Includes scannen. Die systemweite ssh_config
    # gilt bewusst nicht als Benutzerbestand.
    __kh_scan_reset
    if [[ -r $config ]]; then
        __kh_scan_file "$config" "$HOME/.ssh" 0
    fi

    # Effektives HostName je konkretem Alias aufloesen. Damit werden auch
    # Hostnamen erfasst, die aus einer allgemeineren Host-Regel stammen.
    for alias in "${__kh_scan_aliases[@]}"; do
        if [[ $config == "$HOME/.ssh/config" ]]; then
            resolved=$(command ssh -G -T "$alias" 2>/dev/null) || continue
        else
            resolved=$(command ssh -G -T -F "$config" "$alias" 2>/dev/null) || continue
        fi

        host=''
        while read -r field value; do
            [[ $field == hostname ]] && {
                host=$value
                break
            }
        done <<< "$resolved"

        if [[ -n $host ]] && name=$(__ssh_resolve_hosts_extract_name "$host" 2>/dev/null); then
            __ssh_resolve_hosts_add_config_ref "$name" "$alias"
        fi
    done

    # Zusaetzlich rohe Host-/HostName-Literale lesen. So erscheinen auch
    # Angaben aus Host-Mustern, fuer die kein konkreter Alias existiert.
    for file in "${__kh_scan_files[@]}"; do
        [[ -r $file ]] || continue
        display_file=$(__ssh_resolve_ips_display_path "$file")
        config_line_number=0
        current_aliases=()

        while IFS= read -r config_line || [[ -n $config_line ]]; do
            ((config_line_number+=1))
            config_line=${config_line%$'\r'}
            config_line=${config_line%%#*}
            config_line=${config_line/=/ }
            read -r -a words <<< "$config_line"
            ((${#words[@]})) || continue

            keyword=${words[0],,}
            case $keyword in
                host)
                    current_aliases=()
                    for token in "${words[@]:1}"; do
                        token=${token#\"}
                        token=${token%\"}
                        [[ -n $token ]] || continue

                        [[ $token != -* && $token != *['*?!']* ]] || continue
                        current_aliases+=("$token")
                    done
                    ;;

                match)
                    current_aliases=()
                    ;;

                hostname)
                    hostname=${words[1]-}
                    hostname=${hostname#\"}
                    hostname=${hostname%\"}
                    [[ -n $hostname ]] || continue
                    [[ $hostname != *['%$']* ]] || continue

                    if name=$(__ssh_resolve_hosts_extract_name "$hostname" 2>/dev/null); then
                        if ((${#current_aliases[@]})); then
                            for alias in "${current_aliases[@]}"; do
                                __ssh_resolve_hosts_add_config_ref "$name" "$alias"
                            done
                        else
                            ref="$display_file:$config_line_number"
                            __ssh_resolve_hosts_add_config_ref "$name" "$ref"
                        fi
                    fi
                    ;;
            esac
        done < "$file"
    done

    # known_hosts: Hostfeld kann mehrere Namen enthalten. Gehashte Eintraege
    # koennen naturgemaess nicht aufgeloest werden.
    if [[ -r $known ]]; then
        line_number=0
        while IFS= read -r line || [[ -n $line ]]; do
            ((line_number+=1))
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*(#|$) ]] && continue

            read -r first second _ <<< "$line"
            if [[ $first == @* ]]; then
                hosts=$second
            else
                hosts=$first
            fi

            [[ -n $hosts && $hosts != '|1|'* ]] || continue
            IFS=',' read -r -a host_tokens <<< "$hosts"

            for token in "${host_tokens[@]}"; do
                if name=$(__ssh_resolve_hosts_extract_name "$token" 2>/dev/null); then
                    __ssh_resolve_hosts_add_known_line "$name" "$line_number"
                fi
            done
        done < "$known"
    fi

    # Keine lokalen Hilfsfunktionen in der interaktiven Shell zuruecklassen.
    unset -f __ssh_resolve_hosts_add_name \
             __ssh_resolve_hosts_add_config_ref \
             __ssh_resolve_hosts_add_known_line

    # Lookups nur einmal pro Hostname. Fehlende Antworten werden als '-' gezeigt.
    for name in "${name_order[@]}"; do
        if __ssh_resolve_hosts_lookup "$name" "$timeout_seconds"; then
            addresses["$name"]=$__ssh_resolve_hosts_lookup_result
        else
            addresses["$name"]='-'
        fi
    done

    filter_lc=${filter,,}
    for ((i=0; i<${#name_order[@]}; i++)); do
        name=${name_order[$i]}
        [[ -n ${config_refs["$name"]} ]] || config_refs["$name"]='-'
        [[ -n ${known_lines["$name"]} ]] || known_lines["$name"]='-'

        search="$name ${addresses["$name"]} ${config_refs["$name"]} ${known_lines["$name"]}"
        [[ -z $filter || ${search,,} == *"$filter_lc"* ]] || continue

        selected+=("$name")
        ((${#name} > w_name)) && w_name=${#name}
        ((${#addresses["$name"]} > w_ip)) && w_ip=${#addresses["$name"]}
        ((${#config_refs["$name"]} > w_config)) && w_config=${#config_refs["$name"]}
        ((${#known_lines["$name"]} > w_known)) && w_known=${#known_lines["$name"]}
    done

    printf '\e[2m%-*s  %-*s  %-*s  %s\e[0m\n' \
        "$w_name" 'HOSTNAME' \
        "$w_ip" 'IP' \
        "$w_config" 'CONFIG' \
        'KNOWN_HOSTS'

    if ((${#selected[@]} == 0)); then
        if [[ -n $filter ]]; then
            printf 'Keine Hostnamen fuer "%s" gefunden.\n' "$filter"
        else
            printf 'Keine Hostnamen in SSH-Config oder known_hosts gefunden.\n'
        fi
        return 0
    fi

    for name in "${selected[@]}"; do
        printf '\e[36m%-*s\e[0m  %-*s  %-*s  \e[33m%s\e[0m\n' \
            "$w_name" "$name" \
            "$w_ip" "${addresses["$name"]}" \
            "$w_config" "${config_refs["$name"]}" \
            "${known_lines["$name"]}"
    done

    return 0
}
