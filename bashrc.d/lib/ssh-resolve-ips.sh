#!/usr/bin/env bash

# __kh_host and __kh_port are set by __kh_split_host_port in lib/ssh-config.sh,
# which the source-time guard below requires.
# shellcheck disable=SC2154

# ssh-resolve-ips: every IP referenced by the SSH config or known_hosts,
# together with its PTR record.
#
# Everything this command shares with ssh-resolve-hosts lives in
# lib/ssh-resolve.sh, which has to be sourced first. What is left here is the
# reverse direction alone: which tokens count as a key, and how a PTR record is
# looked up.

# Reverse-DNS cache for this shell. A --refresh only discards the DNS results;
# known_hosts and the SSH config are re-read on every call.
declare -F __ssh_resolve_table >/dev/null || {
    printf '%s: lib/ssh-resolve.sh has to be sourced first.\n' "${BASH_SOURCE[0]##*/}" >&2
    return 1
}

declare -A __ssh_resolve_ips_dns_cache=()

__ssh_resolve_ips_cache_invalidate() {
    __ssh_resolve_ips_dns_cache=()
}
__ssh_cache_register_invalidator __ssh_resolve_ips_cache_invalidate

# Extracts the IP from a known_hosts or config token. Also supports [IPv4]:port
# and [IPv6]:port. Hostnames are ignored; they are ssh-resolve-hosts's business.
__ssh_resolve_ips_extract_ip() {
    __kh_split_host_port "$1"

    if __ssh_resolve_is_ip "$__kh_host"; then
        printf '%s\n' "$__kh_host"
        return 0
    fi

    return 1
}

# Reverse resolution with portable backends. On Git Bash/Windows, PowerShell is
# the most reliable fallback because it prints the hostname only.
__ssh_resolve_ips_lookup_uncached() {
    local ip=$1 timeout_seconds=$2 output='' ps_script=''

    if command -v getent >/dev/null 2>&1; then
        output=$(
            __ssh_resolve_run_with_timeout "$timeout_seconds" \
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
            __ssh_resolve_run_with_timeout "$timeout_seconds" \
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
            __ssh_resolve_run_with_timeout "$timeout_seconds" \
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
            __ssh_resolve_run_with_timeout "$timeout_seconds" \
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
            __ssh_resolve_run_with_timeout "$timeout_seconds" \
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

# ssh-resolve-ips [FILTER | --refresh | --help]
#
# Shows every IP found once and merges the references from the SSH config and
# known_hosts. Reverse-DNS results are cached within the shell; --refresh
# forces fresh PTR lookups.
# The resolve_* locals below are the spec __ssh_resolve_table reads back
# through dynamic scoping, so they look unused from here.
# shellcheck disable=SC2034
ssh_resolve_ips() {
    declare -F __ssh_resolve_table >/dev/null || {
        printf 'ssh-resolve-ips: lib/ssh-resolve.sh has not been loaded.\n' >&2
        return 1
    }

    local resolve_command='ssh-resolve-ips'
    local resolve_extract='__ssh_resolve_ips_extract_ip'
    local resolve_lookup='__ssh_resolve_ips_lookup'
    local resolve_result='__ssh_resolve_ips_lookup_result'
    local resolve_invalidate='__ssh_resolve_ips_cache_invalidate'
    local resolve_timeout_var='SSH_RESOLVE_IP_TIMEOUT'
    local resolve_key_header='IP'
    local resolve_value_header='HOSTNAME'
    local resolve_noun='IP entries'
    # An IP literal used directly as a Host pattern is worth listing.
    local resolve_scan_host_tokens=1
    local timeout_seconds=${SSH_RESOLVE_IP_TIMEOUT:-3}
    local -a resolve_help=(
        'Resolves IPs from known_hosts and the SSH config via reverse DNS.'
    )

    __ssh_resolve_table "$@"
}
