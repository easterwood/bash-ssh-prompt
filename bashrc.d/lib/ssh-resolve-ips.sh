#!/usr/bin/env bash

# Reverse-DNS cache for this shell. A --refresh only discards the DNS results;
# known_hosts and the SSH config are re-read on every call.
declare -A __ssh_resolve_ips_dns_cache=()

__ssh_resolve_ips_cache_invalidate() {
    __ssh_resolve_ips_dns_cache=()
}

__ssh_resolve_ips_is_ipv4() {
    local ip=$1 part
    local -a octets

    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"

    for part in "${octets[@]}"; do
        ((10#$part <= 255)) || return 1
    done

    return 0
}

__ssh_resolve_ips_is_ipv6() {
    local ip=${1%%%*}

    [[ $ip == *:* ]] || return 1
    [[ $ip != *[^0-9A-Fa-f:.]* ]] || return 1
    [[ $ip == *:*:* ]] || return 1
    return 0
}

__ssh_resolve_ips_is_ip() {
    __ssh_resolve_ips_is_ipv4 "$1" || __ssh_resolve_ips_is_ipv6 "$1"
}

# Extracts the IP from a known_hosts host token. Also supports [IPv4]:port and
# [IPv6]:port. Other hostnames are ignored.
__ssh_resolve_ips_extract_ip() {
    local token=$1 host

    if [[ $token =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
        host=${BASH_REMATCH[1]}
    else
        host=$token
    fi

    if __ssh_resolve_ips_is_ip "$host"; then
        printf '%s\n' "$host"
        return 0
    fi

    return 1
}

__ssh_resolve_ips_run_with_timeout() {
    local seconds=$1
    shift

    if command -v timeout >/dev/null 2>&1; then
        command timeout "${seconds}s" "$@"
    else
        "$@"
    fi
}

# Reverse resolution with portable backends. On Git Bash/Windows, PowerShell is
# the most reliable fallback because it prints the hostname only.
__ssh_resolve_ips_lookup_uncached() {
    local ip=$1 timeout_seconds=$2 output='' ps_script=''

    if command -v getent >/dev/null 2>&1; then
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                getent hosts "$ip" 2>/dev/null |
            awk 'NF >= 2 { print $2; exit }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "${output%.}"
            return 0
        }
    fi

    if command -v dig >/dev/null 2>&1; then
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                dig +short -x "$ip" 2>/dev/null |
            awk 'NF { print; exit }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "${output%.}"
            return 0
        }
    fi

    if command -v host >/dev/null 2>&1; then
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                host "$ip" 2>/dev/null |
            awk '/[[:space:]]pointer[[:space:]]/ { print $NF; exit }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "${output%.}"
            return 0
        }
    fi

    if command -v powershell.exe >/dev/null 2>&1; then
        printf -v ps_script \
            "try { [Console]::Out.WriteLine([System.Net.Dns]::GetHostEntry('%s').HostName) } catch { exit 1 }" \
            "$ip"
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                powershell.exe -NoProfile -NonInteractive -Command "$ps_script" \
                2>/dev/null |
            tr -d '\r' |
            awk 'NF { print; exit }'
        )
        [[ -z $output ]] || {
            printf '%s\n' "${output%.}"
            return 0
        }
    fi

    if command -v nslookup >/dev/null 2>&1; then
        output=$(
            __ssh_resolve_ips_run_with_timeout "$timeout_seconds" \
                nslookup "$ip" 2>/dev/null |
            awk '
                /[[:space:]]name[[:space:]]*=/ {
                    value=$0
                    sub(/^.*[[:space:]]name[[:space:]]*=[[:space:]]*/, "", value)
                    print value
                    exit
                }
                /^[[:space:]]*Name:[[:space:]]*/ {
                    value=$0
                    sub(/^[[:space:]]*Name:[[:space:]]*/, "", value)
                    print value
                    exit
                }
            '
        )
        [[ -z $output ]] || {
            printf '%s\n' "${output%.}"
            return 0
        }
    fi

    return 1
}

__ssh_resolve_ips_lookup_result=''

__ssh_resolve_ips_lookup() {
    local ip=$1 timeout_seconds=$2 cached result

    __ssh_resolve_ips_lookup_result=''

    if [[ -n ${__ssh_resolve_ips_dns_cache["$ip"]+x} ]]; then
        cached=${__ssh_resolve_ips_dns_cache["$ip"]}
        [[ $cached != $'\x1e' ]] || return 1
        __ssh_resolve_ips_lookup_result=$cached
        return 0
    fi

    if result=$(__ssh_resolve_ips_lookup_uncached "$ip" "$timeout_seconds"); then
        __ssh_resolve_ips_dns_cache["$ip"]=$result
        __ssh_resolve_ips_lookup_result=$result
        return 0
    fi

    # Sentinel for a failed PTR lookup.
    __ssh_resolve_ips_dns_cache["$ip"]=$'\x1e'
    return 1
}

__ssh_resolve_ips_display_path() {
    local path=$1

    case $path in
        "$HOME"/*) printf '~/%s\n' "${path#"$HOME"/}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

# ssh-resolve-ips [FILTER | --refresh | --help]
#
# Shows every IP found once and merges the references from the SSH config and
# known_hosts. Reverse-DNS results are cached within the shell; --refresh forces
# fresh PTR lookups.
ssh_resolve_ips() {
    local known=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local timeout_seconds=${SSH_RESOLVE_IP_TIMEOUT:-3}
    local filter=${1-}

    local line line_number first second hosts token ip host resolved field value
    local file config_line_number keyword alias ref display_file hostname
    local i search filter_lc ptr
    local -a host_tokens=() words=() current_aliases=() selected=()
    local -A ip_seen=() config_ref_seen=() known_line_seen=()
    local -a ip_order=()
    local -A config_refs=() known_lines=() hostnames=()
    local w_ip=2 w_hostname=8 w_config=6 w_known=11

    if (( $# > 1 )); then
        printf 'Usage: ssh-resolve-ips [FILTER | --refresh | --help]\n' >&2
        return 2
    fi

    case $filter in
        --help|-h)
            printf 'Usage: ssh-resolve-ips [FILTER | --refresh | --help]\n'
            printf 'Resolves IPs from known_hosts and the SSH config via reverse DNS.\n'
            printf 'Environment variable: SSH_RESOLVE_IP_TIMEOUT (default: 3 seconds).\n'
            return 0
            ;;
        --refresh)
            __ssh_resolve_ips_cache_invalidate
            filter=''
            ;;
    esac

    [[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
        printf 'ssh-resolve-ips: invalid timeout: %s\n' "$timeout_seconds" >&2
        return 2
    }

    # Local helper logic on top of the global result arrays: record the IP in a
    # stable order and deduplicate the references.
    __ssh_resolve_ips_add_ip() {
        local add_ip=$1
        [[ -n ${ip_seen["$add_ip"]+x} ]] || {
            ip_seen["$add_ip"]=1
            ip_order+=("$add_ip")
            config_refs["$add_ip"]=''
            known_lines["$add_ip"]=''
        }
    }

    __ssh_resolve_ips_add_config_ref() {
        local add_ip=$1 add_ref=$2 key
        __ssh_resolve_ips_add_ip "$add_ip"
        key="$add_ip"$'\x1f'"$add_ref"
        [[ -z ${config_ref_seen["$key"]+x} ]] || return 0
        config_ref_seen["$key"]=1
        if [[ -n ${config_refs["$add_ip"]} ]]; then
            config_refs["$add_ip"]+=", $add_ref"
        else
            config_refs["$add_ip"]=$add_ref
        fi
    }

    __ssh_resolve_ips_add_known_line() {
        local add_ip=$1 add_line=$2 key
        __ssh_resolve_ips_add_ip "$add_ip"
        key="$add_ip"$'\x1f'"$add_line"
        [[ -z ${known_line_seen["$key"]+x} ]] || return 0
        known_line_seen["$key"]=1
        if [[ -n ${known_lines["$add_ip"]} ]]; then
            known_lines["$add_ip"]+=",$add_line"
        else
            known_lines["$add_ip"]=$add_line
        fi
    }

    # Scan the user config and its includes. The system-wide ssh_config is
    # deliberately not treated as part of the user's own inventory.
    __kh_scan_reset
    if [[ -r $config ]]; then
        __kh_scan_file "$config" "$HOME/.ssh" 0
    fi

    # Resolve the effective HostName for every concrete config alias. That also
    # catches IPs coming from a more general Host rule.
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

        if [[ -n $host ]] && ip=$(__ssh_resolve_ips_extract_ip "$host" 2>/dev/null); then
            __ssh_resolve_ips_add_config_ref "$ip" "$alias"
        fi
    done

    # Additionally read raw Host/HostName IP literals. That way entries from
    # host patterns without a concrete alias show up as well.
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

                        if ip=$(__ssh_resolve_ips_extract_ip "$token" 2>/dev/null); then
                            __ssh_resolve_ips_add_config_ref "$ip" "$token"
                        fi

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

                    if ip=$(__ssh_resolve_ips_extract_ip "$hostname" 2>/dev/null); then
                        if ((${#current_aliases[@]})); then
                            for alias in "${current_aliases[@]}"; do
                                __ssh_resolve_ips_add_config_ref "$ip" "$alias"
                            done
                        else
                            ref="$display_file:$config_line_number"
                            __ssh_resolve_ips_add_config_ref "$ip" "$ref"
                        fi
                    fi
                    ;;
            esac
        done < "$file"
    done

    # known_hosts: the host field may contain several names/IPs. Hashed hosts
    # cannot, by their nature, be traced back to an IP.
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
                if ip=$(__ssh_resolve_ips_extract_ip "$token" 2>/dev/null); then
                    __ssh_resolve_ips_add_known_line "$ip" "$line_number"
                fi
            done
        done < "$known"
    fi

    # Do not leave local helper functions behind in the interactive shell.
    unset -f __ssh_resolve_ips_add_ip \
             __ssh_resolve_ips_add_config_ref \
             __ssh_resolve_ips_add_known_line

    # PTR lookups only once per IP. Missing PTR records are shown as '-'.
    for ip in "${ip_order[@]}"; do
        if __ssh_resolve_ips_lookup "$ip" "$timeout_seconds"; then
            hostnames["$ip"]=$__ssh_resolve_ips_lookup_result
        else
            hostnames["$ip"]='-'
        fi
    done

    filter_lc=${filter,,}
    for ((i=0; i<${#ip_order[@]}; i++)); do
        ip=${ip_order[$i]}
        [[ -n ${config_refs["$ip"]} ]] || config_refs["$ip"]='-'
        [[ -n ${known_lines["$ip"]} ]] || known_lines["$ip"]='-'

        search="$ip ${hostnames["$ip"]} ${config_refs["$ip"]} ${known_lines["$ip"]}"
        [[ -z $filter || ${search,,} == *"$filter_lc"* ]] || continue

        selected+=("$ip")
        ((${#ip} > w_ip)) && w_ip=${#ip}
        ((${#hostnames["$ip"]} > w_hostname)) && w_hostname=${#hostnames["$ip"]}
        ((${#config_refs["$ip"]} > w_config)) && w_config=${#config_refs["$ip"]}
        ((${#known_lines["$ip"]} > w_known)) && w_known=${#known_lines["$ip"]}
    done

    printf '\e[2m%-*s  %-*s  %-*s  %s\e[0m\n' \
        "$w_ip" 'IP' \
        "$w_hostname" 'HOSTNAME' \
        "$w_config" 'CONFIG' \
        'KNOWN_HOSTS'

    if ((${#selected[@]} == 0)); then
        if [[ -n $filter ]]; then
            printf 'No IP entries found for "%s".\n' "$filter"
        else
            printf 'No IP entries found in the SSH config or known_hosts.\n'
        fi
        return 0
    fi

    for ip in "${selected[@]}"; do
        printf '\e[36m%-*s\e[0m  %-*s  %-*s  \e[33m%s\e[0m\n' \
            "$w_ip" "$ip" \
            "$w_hostname" "${hostnames["$ip"]}" \
            "$w_config" "${config_refs["$ip"]}" \
            "${known_lines["$ip"]}"
    done

    return 0
}
