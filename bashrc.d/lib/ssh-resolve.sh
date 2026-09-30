#!/usr/bin/env bash

# Shared machinery behind ssh-resolve-ips and ssh-resolve-hosts.
#
# The two commands differ in exactly three things: which tokens they accept as
# a key, which direction they ask DNS, and what the two leading columns are
# called. Everything else — option handling, the config scan, the known_hosts
# scan, deduplication, the filter, the column widths and the output — used to
# exist twice, character for character, with the identifiers renamed.
#
# __ssh_resolve_table implements that shared part once. A command configures it
# by setting a handful of locals before calling it; Bash's dynamic scoping
# makes them visible here. See ssh-resolve-ips.sh for a worked example.
#
# This file requires lib/ssh-config.sh for the shared SSH inventory and the
# known_hosts parser.

declare -F __ssh_inventory_ensure >/dev/null || {
    printf 'ssh-resolve.sh: lib/ssh-config.sh has to be sourced first.\n' >&2
    return 1
}

# --- IP predicates ---------------------------------------------------------

__ssh_resolve_is_ipv4() {
    local ip=$1 part
    local -a octets

    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"

    for part in "${octets[@]}"; do
        ((10#$part <= 255)) || return 1
    done

    return 0
}

__ssh_resolve_ipv6_side_count() {
    local side=$1 part
    local -a groups=()

    REPLY=0
    [[ -n $side ]] || return 0
    [[ $side != :* && $side != *: ]] || return 1

    IFS=: read -r -a groups <<< "$side"
    for part in "${groups[@]}"; do
        [[ $part =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done

    REPLY=${#groups[@]}
}

__ssh_resolve_is_ipv6() {
    local ip=$1 zone='' ipv4='' left='' right=''
    local left_count=0 right_count=0

    [[ $ip == *:* ]] || return 1

    # A scoped literal such as fe80::1%eth0 is valid, but the zone itself must
    # be present exactly once and contain only interface-name-safe characters.
    if [[ $ip == *%* ]]; then
        zone=${ip#*%}
        ip=${ip%%\%*}
        [[ -n $zone && $zone != *%* && $zone != *[^[:alnum:]_.-]* ]] || return 1
    fi

    [[ -n $ip && $ip != *[^0-9A-Fa-f:.]* ]] || return 1
    [[ $ip != *:::* ]] || return 1

    # An embedded IPv4 tail consumes two of the eight 16-bit groups.
    if [[ $ip == *.* ]]; then
        ipv4=${ip##*:}
        [[ $ipv4 != "$ip" ]] || return 1
        __ssh_resolve_is_ipv4 "$ipv4" || return 1
        ip="${ip%:*}:0:0"
    fi

    if [[ $ip == *::* ]]; then
        left=${ip%%::*}
        right=${ip#*::}
        [[ $right != *::* ]] || return 1

        __ssh_resolve_ipv6_side_count "$left" || return 1
        left_count=$REPLY
        __ssh_resolve_ipv6_side_count "$right" || return 1
        right_count=$REPLY

        # :: must stand for at least one omitted 16-bit group.
        (( left_count + right_count < 8 )) || return 1
    else
        __ssh_resolve_ipv6_side_count "$ip" || return 1
        (( REPLY == 8 )) || return 1
    fi

    return 0
}

__ssh_resolve_is_ip() {
    __ssh_resolve_is_ipv4 "$1" || __ssh_resolve_is_ipv6 "$1"
}

# --- helpers ---------------------------------------------------------------

__ssh_resolve_run_with_timeout() {
    local seconds=$1
    shift

    if command -v timeout >/dev/null 2>&1; then
        command timeout "${seconds}s" "$@"
    else
        "$@"
    fi
}

# The tilde here is output, not a path to expand: "~/.ssh/config" is what the
# CONFIG column should read.
# shellcheck disable=SC2088
__ssh_resolve_display_path() {
    local path=$1

    case $path in
        "$HOME"/*) printf '~/%s\n' "${path#"$HOME"/}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

# Accumulators. They operate on the caller's locals (key_seen, key_order,
# config_refs, known_lines and the two *_seen maps), which __ssh_resolve_table
# declares.
__ssh_resolve_add_key() {
    local key=$1
    [[ -n ${key_seen["$key"]+x} ]] || {
        key_seen["$key"]=1
        key_order+=("$key")
        config_refs["$key"]=''
        known_lines["$key"]=''
    }
}

__ssh_resolve_add_config_ref() {
    local key=$1 ref=$2 token
    __ssh_resolve_add_key "$key"
    token="$key"$'\x1f'"$ref"
    [[ -z ${config_ref_seen["$token"]+x} ]] || return 0
    config_ref_seen["$token"]=1
    if [[ -n ${config_refs["$key"]} ]]; then
        config_refs["$key"]+=", $ref"
    else
        config_refs["$key"]=$ref
    fi
}

__ssh_resolve_add_known_line() {
    local key=$1 number=$2 token
    __ssh_resolve_add_key "$key"
    token="$key"$'\x1f'"$number"
    [[ -z ${known_line_seen["$token"]+x} ]] || return 0
    known_line_seen["$token"]=1
    if [[ -n ${known_lines["$key"]} ]]; then
        known_lines["$key"]+=",$number"
    else
        known_lines["$key"]=$number
    fi
}

# --- the shared command ----------------------------------------------------

# __ssh_resolve_table [FILTER | --refresh | --help]
#
# The caller sets, as locals:
#   resolve_command           the user-visible command name
#   resolve_extract           function: TOKEN -> prints the key, returns 1 to skip
#   resolve_lookup            function: KEY TIMEOUT -> returns 0 and fills the
#                             variable named by resolve_result
#   resolve_result            name of that variable
#   resolve_invalidate        function clearing the DNS cache, for --refresh
#   resolve_timeout_var       name of the timeout environment variable
#   resolve_help              array of description lines for --help
#   resolve_key_header        header of column one
#   resolve_value_header      header of column two
#   resolve_noun              plural used in the "nothing found" messages
#   resolve_scan_host_tokens  1 to also read keys out of "Host" tokens
#   timeout_seconds           the effective timeout
# Conversely, every resolve_* name read here is set by the calling command,
# and the accumulators above work on that caller's maps.
# shellcheck disable=SC2154
__ssh_resolve_table() {
    local known=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local filter=${1-}

    local line line_number token key value resolved host
    local file config_line config_line_number keyword alias ref display_file hostname
    local search filter_lc
    local -a host_tokens=() words=() current_aliases=() selected=()
    local -A key_seen=() config_ref_seen=() known_line_seen=()
    local -a key_order=()
    local -A config_refs=() known_lines=() values=()
    local w_key=${#resolve_key_header} w_value=${#resolve_value_header}
    local w_config=6 w_known=11

    if (( $# > 1 )); then
        printf 'Usage: %s [FILTER | --refresh | --help]\n' "$resolve_command" >&2
        return 2
    fi

    case $filter in
        --help|-h)
            printf 'Usage: %s [FILTER | --refresh | --help]\n' "$resolve_command"
            printf '%s\n' "${resolve_help[@]}"
            printf 'Environment variable: %s (default: 3 seconds).\n' "$resolve_timeout_var"
            return 0
            ;;
        --refresh)
            "$resolve_invalidate"
            filter=''
            ;;
    esac

    [[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
        printf '%s: invalid timeout: %s\n' "$resolve_command" "$timeout_seconds" >&2
        return 2
    }

    # Share the same file snapshots and ssh -G results as known-hosts and
    # completion. The resolver still considers only the user-config subset
    # when attributing CONFIG references.
    __ssh_inventory_ensure "$known" "$config"

    # Resolve the effective HostName for every concrete user-config alias. That
    # also catches keys coming from a more general Host rule.
    for alias in "${__ssh_inventory_user_aliases[@]}"; do
        __ssh_inventory_target_dump "$config" "$alias" 1 || continue
        resolved=$REPLY

        __kh_ssh_config_field "$resolved" hostname || continue
        host=$REPLY
        [[ -n $host ]] || continue

        if key=$("$resolve_extract" "$host" 2>/dev/null); then
            __ssh_resolve_add_config_ref "$key" "$alias"
        fi
    done

    # Additionally read raw Host/HostName literals, so entries from host
    # patterns without a concrete alias show up as well.
    for file in "${__ssh_inventory_user_files[@]}"; do
        [[ ${__ssh_inventory_file_readable["$file"]-0} == 1 ]] || continue
        display_file=$(__ssh_resolve_display_path "$file")
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

                        if (( resolve_scan_host_tokens )) &&
                           key=$("$resolve_extract" "$token" 2>/dev/null); then
                            __ssh_resolve_add_config_ref "$key" "$token"
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
                    # %h and friends would have to be expanded with OpenSSH's
                    # own substitution rules, so such tokens are left alone.
                    [[ $hostname != *['%$']* ]] || continue

                    if key=$("$resolve_extract" "$hostname" 2>/dev/null); then
                        if ((${#current_aliases[@]})); then
                            for alias in "${current_aliases[@]}"; do
                                __ssh_resolve_add_config_ref "$key" "$alias"
                            done
                        else
                            ref="$display_file:$config_line_number"
                            __ssh_resolve_add_config_ref "$key" "$ref"
                        fi
                    fi
                    ;;
            esac
        done <<< "${__ssh_inventory_file_content["$file"]-}"
    done

    # known_hosts: the host field may carry several names. Hashed entries
    # cannot, by their nature, be traced back to anything.
    if (( __ssh_inventory_known_readable )); then
        line_number=0
        while IFS= read -r line || [[ -n $line ]]; do
            ((line_number+=1))
            __kh_parse_known_line "$line" || continue
            (( ! __kh_line_hashed )) || continue

            IFS=',' read -r -a host_tokens <<< "$__kh_line_hosts"

            for token in "${host_tokens[@]}"; do
                if key=$("$resolve_extract" "$token" 2>/dev/null); then
                    __ssh_resolve_add_known_line "$key" "$line_number"
                fi
            done
        done <<< "$__ssh_inventory_known_content"
    fi

    # One lookup per key. Missing answers are shown as '-'.
    for key in "${key_order[@]}"; do
        if "$resolve_lookup" "$key" "$timeout_seconds"; then
            values["$key"]=${!resolve_result}
        else
            values["$key"]='-'
        fi
    done

    filter_lc=${filter,,}
    for key in "${key_order[@]}"; do
        [[ -n ${config_refs["$key"]} ]] || config_refs["$key"]='-'
        [[ -n ${known_lines["$key"]} ]] || known_lines["$key"]='-'

        value=${values["$key"]}
        search="$key $value ${config_refs["$key"]} ${known_lines["$key"]}"
        [[ -z $filter || ${search,,} == *"$filter_lc"* ]] || continue

        selected+=("$key")
        ((${#key} > w_key)) && w_key=${#key}
        ((${#value} > w_value)) && w_value=${#value}
        ((${#config_refs["$key"]} > w_config)) && w_config=${#config_refs["$key"]}
        ((${#known_lines["$key"]} > w_known)) && w_known=${#known_lines["$key"]}
    done

    printf '\e[2m%-*s  %-*s  %-*s  %s\e[0m\n' \
        "$w_key" "$resolve_key_header" \
        "$w_value" "$resolve_value_header" \
        "$w_config" 'CONFIG' \
        'KNOWN_HOSTS'

    if ((${#selected[@]} == 0)); then
        if [[ -n $filter ]]; then
            printf 'No %s found for "%s".\n' "$resolve_noun" "$filter"
        else
            printf 'No %s found in the SSH config or known_hosts.\n' "$resolve_noun"
        fi
        return 0
    fi

    for key in "${selected[@]}"; do
        printf '\e[36m%-*s\e[0m  %-*s  %-*s  \e[33m%s\e[0m\n' \
            "$w_key" "$key" \
            "$w_value" "${values["$key"]}" \
            "$w_config" "${config_refs["$key"]}" \
            "${known_lines["$key"]}"
    done

    return 0
}
