#!/usr/bin/env bash

# __kh_host and __kh_port are set by __kh_split_host_port in lib/ssh-config.sh,
# which the source-time guard below requires.
# shellcheck disable=SC2154

# ssh-resolve-hosts: every hostname referenced by the SSH config or
# known_hosts, together with the addresses it resolves to. Counterpart to
# ssh-resolve-ips.
#
# Everything the two commands share lives in lib/ssh-resolve.sh, which has to
# be sourced first. What is left here is the forward direction alone.

# Forward-DNS cache for this shell. --refresh only discards the DNS results;
# known_hosts and the SSH config are re-read on every call.
declare -F __ssh_resolve_table >/dev/null || {
    printf '%s: lib/ssh-resolve.sh has to be sourced first.\n' "${BASH_SOURCE[0]##*/}" >&2
    return 1
}

declare -A __ssh_resolve_hosts_dns_cache=()

__ssh_resolve_hosts_cache_invalidate() {
    __ssh_resolve_hosts_dns_cache=()
}
__ssh_cache_register_invalidator __ssh_resolve_hosts_cache_invalidate

# Extracts a resolvable hostname from a token. Also supports [host]:port.
# IP literals and patterns are skipped on purpose: the IP side is covered by
# ssh-resolve-ips.
__ssh_resolve_hosts_extract_name() {
    __kh_split_host_port "$1"
    local host=$__kh_host

    [[ -n $host ]] || return 1
    [[ $host != *['*?!']* ]] || return 1
    [[ $host != @* ]] || return 1
    __ssh_resolve_is_ip "$host" && return 1

    printf '%s\n' "${host%.}"
    return 0
}

# Forward resolution with portable backends, one function per tool. The chain
# that tries them in order lives in lib/ssh-resolve.sh, and the order is the
# same as in ssh-resolve-ips.sh.
#
# A backend may print anything; __ssh_resolve_hosts_lookup below keeps only
# what parses as an IP literal, so a parser that lets a stray line through
# cannot put junk in the column.

# getent ahosts repeats an address once per socket type.
__ssh_resolve_hosts_via_getent() {
    __ssh_resolve_run_with_timeout "$2" getent ahosts "$1" |
        awk 'NF { print $1 }'
}

# dig answers one record type per call, so this is the one backend that asks
# twice.
__ssh_resolve_hosts_via_dig() {
    {
        __ssh_resolve_run_with_timeout "$2" dig +short "$1" A
        __ssh_resolve_run_with_timeout "$2" dig +short "$1" AAAA
    } | awk 'NF { print }'
}

__ssh_resolve_hosts_via_host() {
    __ssh_resolve_run_with_timeout "$2" host "$1" |
        awk '/has (IPv6 )?address/ { print $NF }'
}

__ssh_resolve_hosts_via_powershell() {
    local script

    printf -v script \
        "try { [System.Net.Dns]::GetHostAddresses('%s') | ForEach-Object { [Console]::Out.WriteLine(\$_.IPAddressToString) } } catch { exit 1 }" \
        "$1"

    __ssh_resolve_run_with_timeout "$2" \
        powershell.exe -NoProfile -NonInteractive -Command "$script" |
        tr -d '\r' |
        awk 'NF { print }'
}

# The addresses printed before the answer section belong to the resolver
# itself, so only what follows "Name:" counts.
__ssh_resolve_hosts_via_nslookup() {
    __ssh_resolve_run_with_timeout "$2" nslookup "$1" |
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
}

__ssh_resolve_hosts_lookup_uncached() {
    __ssh_resolve_backend_chain "$2" "$1" \
        getent=__ssh_resolve_hosts_via_getent \
        dig=__ssh_resolve_hosts_via_dig \
        host=__ssh_resolve_hosts_via_host \
        powershell.exe=__ssh_resolve_hosts_via_powershell \
        nslookup=__ssh_resolve_hosts_via_nslookup || return 1

    printf '%s\n' "$__ssh_resolve_backend_output"
}

__ssh_resolve_hosts_lookup_result=''

# The result is a comma-separated list, IPv4 before IPv6.
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

        if __ssh_resolve_is_ipv4 "$candidate"; then
            seen["$candidate"]=1
            if [[ -n $ipv4_list ]]; then
                ipv4_list+=", $candidate"
            else
                ipv4_list=$candidate
            fi
        elif __ssh_resolve_is_ipv6 "$candidate"; then
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
        # Sentinel for a failed resolution.
        __ssh_resolve_hosts_dns_cache["$name"]=$'\x1e'
        return 1
    fi

    __ssh_resolve_hosts_dns_cache["$name"]=$joined
    __ssh_resolve_hosts_lookup_result=$joined
    return 0
}

# ssh-resolve-hosts [FILTER | --refresh | --help]
#
# Shows every hostname found once and merges the references from the SSH config
# and known_hosts. DNS results are cached within the shell; --refresh forces
# fresh lookups.
# The resolve_* locals below are the spec __ssh_resolve_table reads back
# through dynamic scoping, so they look unused from here.
# shellcheck disable=SC2034
ssh_resolve_hosts() {
    declare -F __ssh_resolve_table >/dev/null || {
        printf 'ssh-resolve-hosts: lib/ssh-resolve.sh has not been loaded.\n' >&2
        return 1
    }

    local resolve_command='ssh-resolve-hosts'
    local resolve_extract='__ssh_resolve_hosts_extract_name'
    local resolve_lookup='__ssh_resolve_hosts_lookup'
    local resolve_result='__ssh_resolve_hosts_lookup_result'
    local resolve_invalidate='__ssh_resolve_hosts_cache_invalidate'
    local resolve_timeout_var='SSH_RESOLVE_HOST_TIMEOUT'
    local resolve_key_header='HOSTNAME'
    local resolve_value_header='IP'
    local resolve_noun='hostnames'
    # A Host token is an alias, not a name to resolve; the alias's effective
    # HostName is already covered by the "ssh -G" pass.
    local resolve_scan_host_tokens=0
    local timeout_seconds=${SSH_RESOLVE_HOST_TIMEOUT:-3}
    local -a resolve_help=(
        'Resolves hostnames from known_hosts and the SSH config to IPs via DNS.'
        'Counterpart to ssh-resolve-ips, which goes the other way round.'
    )

    __ssh_resolve_table "$@"
}
