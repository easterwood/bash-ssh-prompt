#!/usr/bin/env bash

# Shared completion view built on lib/ssh-config.sh's SSH inventory cache.
# Completion owns only its derived host/user lists; file watching, Include
# invalidation and cached ssh -G results live in one place for every consumer.

# The __ssh_inventory_* and __kh_* globals read here are defined in
# lib/ssh-config.sh. bashrc.d/ssh-tools.sh guarantees the load order.
# shellcheck disable=SC2154

declare -F __ssh_inventory_ensure >/dev/null || {
    printf 'ssh-hosts.bash: lib/ssh-config.sh has to be sourced first.\n' >&2
    return 1
}

declare -a __ssh_completion_filter_hosts=()
declare -a __ssh_completion_connect_hosts=()
declare -a __ssh_completion_connect_targets=()
declare -A __ssh_completion_filter_seen=()
declare -A __ssh_completion_connect_seen=()
declare -A __ssh_completion_target_seen=()
declare -A __ssh_completion_user_host=()
__ssh_completion_inventory_generation=-1

__ssh_completion_cache_invalidate() {
    __ssh_completion_inventory_generation=-1
    __ssh_completion_filter_hosts=()
    __ssh_completion_connect_hosts=()
    __ssh_completion_connect_targets=()
    __ssh_completion_filter_seen=()
    __ssh_completion_connect_seen=()
    __ssh_completion_target_seen=()
    __ssh_completion_user_host=()
}
__ssh_cache_register_invalidator __ssh_completion_cache_invalidate

__ssh_completion_add_filter_host() {
    local host=$1
    [[ -n $host && -z ${__ssh_completion_filter_seen["$host"]+x} ]] || return 0
    __ssh_completion_filter_seen["$host"]=1
    __ssh_completion_filter_hosts+=("$host")
}

__ssh_completion_add_connect_host() {
    local host=$1
    [[ -n $host && -z ${__ssh_completion_connect_seen["$host"]+x} ]] || return 0
    __ssh_completion_connect_seen["$host"]=1
    __ssh_completion_connect_hosts+=("$host")
}

__ssh_completion_add_user_host() {
    local user=$1 host=$2 key target

    [[ -n $user && -n $host ]] || return 0

    key="$user"$'\x1f'"$host"
    __ssh_completion_user_host["$key"]=1

    target="$user@$host"
    [[ -z ${__ssh_completion_target_seen["$target"]+x} ]] || return 0
    __ssh_completion_target_seen["$target"]=1
    __ssh_completion_connect_targets+=("$target")
}

__ssh_completion_resolve_user() {
    local config=$1 alias=$2

    __ssh_inventory_target_field "$config" "$alias" user 1 || return 1
    [[ -n $REPLY ]]
}

__ssh_completion_refresh() {
    local known=$1 config=$2
    local host hosts user line
    local -a host_list=()

    __ssh_inventory_ensure "$known" "$config"
    __ssh_completion_cache_invalidate

    # Explicit config aliases are always valid connection targets. Resolve the
    # effective User through the shared ssh -G cache so later known-hosts or
    # resolver calls do not execute the same lookup again.
    for host in "${__ssh_inventory_aliases[@]}"; do
        __ssh_completion_add_filter_host "$host"
        __ssh_completion_add_connect_host "$host"

        user=''
        if __ssh_completion_resolve_user "$config" "$host"; then
            user=$REPLY
        fi
        [[ -z $user ]] || __ssh_completion_add_user_host "$user" "$host"
    done

    # known_hosts is useful for filtering. For ssh/sshp only plain hostnames
    # are added; entries such as [host]:2222 are not valid ssh destinations.
    if (( __ssh_inventory_known_readable )); then
        while IFS= read -r line || [[ -n $line ]]; do
            __kh_parse_known_line "$line" || continue
            (( ! __kh_line_hashed )) || continue
            hosts=$__kh_line_hosts
            IFS=',' read -r -a host_list <<< "$hosts"

            for host in "${host_list[@]}"; do
                [[ -n $host ]] || continue
                __ssh_completion_add_filter_host "$host"

                # Do not offer known_hosts syntax, patterns or markers as an
                # ssh destination. Config aliases above are not restricted.
                [[ $host != \[*\]:* &&
                   $host != *['*?!']* &&
                   $host != @* ]] || continue
                __ssh_completion_add_connect_host "$host"
            done
        done <<< "$__ssh_inventory_known_content"
    fi

    __ssh_completion_inventory_generation=$__ssh_inventory_generation
}

__ssh_completion_cache_ensure() {
    local known=${1:-${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}}
    local config=${2:-${SSH_CONFIG_FILE:-$HOME/.ssh/config}}

    __ssh_inventory_ensure "$known" "$config"
    if [[ $__ssh_completion_inventory_generation != "$__ssh_inventory_generation" ]]; then
        __ssh_completion_refresh "$known" "$config"
    fi
}
