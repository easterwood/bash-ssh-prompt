#!/usr/bin/env bash

# The __kh_* globals read here are defined in lib/ssh-config.sh and filled by
# its scanner and parser; bashrc.d/ssh-tools.sh guarantees the load order and
# every file checks it at source time. ShellCheck sees one file at a time.
# shellcheck disable=SC2154

# Shared lazy host cache for all SSH completions.
# The cache is built on the first TAB and refreshed when config/includes or
# known_hosts change.
declare -a __ssh_completion_filter_hosts=()
declare -a __ssh_completion_connect_hosts=()
declare -a __ssh_completion_connect_targets=()
declare -a __ssh_completion_config_files=()
declare -a __ssh_completion_include_patterns=()
declare -A __ssh_completion_config_content=()
declare -A __ssh_completion_config_readable=()
declare -A __ssh_completion_include_matches=()
declare -A __ssh_completion_filter_seen=()
declare -A __ssh_completion_connect_seen=()
declare -A __ssh_completion_target_seen=()
declare -A __ssh_completion_user_host=()
__ssh_completion_cache_id=''
__ssh_completion_known_content=''
__ssh_completion_known_readable=0

__ssh_completion_cache_invalidate() {
    __ssh_completion_cache_id=''
    __ssh_completion_filter_hosts=()
    __ssh_completion_connect_hosts=()
    __ssh_completion_connect_targets=()
    __ssh_completion_filter_seen=()
    __ssh_completion_connect_seen=()
    __ssh_completion_target_seen=()
    __ssh_completion_user_host=()
}

__ssh_completion_cache_valid() {
    local known=$1 config=$2 file pattern current readable

    [[ $__ssh_completion_cache_id == "$known|$config" ]] || return 1

    if [[ -r $known ]]; then
        readable=1
        current=$(< "$known")
    else
        readable=0
        current=''
    fi
    [[ $__ssh_completion_known_readable == "$readable" ]] || return 1
    [[ $__ssh_completion_known_content == "$current" ]] || return 1

    for file in "${__ssh_completion_config_files[@]}"; do
        if [[ -r $file ]]; then
            readable=1
            current=$(< "$file")
        else
            readable=0
            current=''
        fi

        [[ ${__ssh_completion_config_readable["$file"]-0} == "$readable" ]] || return 1
        [[ ${__ssh_completion_config_content["$file"]-} == "$current" ]] || return 1
    done

    # compgen is a Bash builtin. This also notices added/removed files that
    # match an existing Include glob.
    for pattern in "${__ssh_completion_include_patterns[@]}"; do
        current=$(compgen -G "$pattern" || true)
        [[ ${__ssh_completion_include_matches["$pattern"]-} == "$current" ]] || return 1
    done

    return 0
}

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

# Resolve the effective SSH user for a concrete config alias. ssh -G does not
# open a connection, but configured Match exec rules may be evaluated.
__ssh_completion_resolve_user() {
    local config=$1 alias=$2 resolved field value

    if [[ $config == "$HOME/.ssh/config" ]]; then
        resolved=$(command ssh -G -T "$alias" 2>/dev/null) || return 1
    else
        resolved=$(command ssh -G -T -F "$config" "$alias" 2>/dev/null) || return 1
    fi

    while read -r field value; do
        if [[ $field == user && -n $value ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done <<< "$resolved"

    return 1
}

__ssh_completion_refresh() {
    local known=$1 config=$2
    local line first second hosts host file pattern current user
    local -a host_list=() watched_files=()
    local -A watched_seen=()

    __ssh_completion_cache_invalidate
    __ssh_completion_config_files=()
    __ssh_completion_include_patterns=()
    __ssh_completion_config_content=()
    __ssh_completion_config_readable=()
    __ssh_completion_include_matches=()

    __kh_scan_configs "$config" 1

    # Explicit config aliases are always valid connection targets. Resolve the
    # effective User once per cache refresh so ssh/sshp can also complete from
    # a user-name prefix, for example "ssh oster<TAB>" -> "osterwald@host".
    for host in "${__kh_scan_aliases[@]}"; do
        __ssh_completion_add_filter_host "$host"
        __ssh_completion_add_connect_host "$host"

        user=$(__ssh_completion_resolve_user "$config" "$host" || true)
        [[ -z $user ]] || __ssh_completion_add_user_host "$user" "$host"
    done

    # known_hosts is useful for filtering. For ssh/sshp only plain hostnames
    # are added; entries such as [host]:2222 are not valid ssh destinations.
    if [[ -r $known ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*(#|$) ]] && continue

            read -r first second _ <<< "$line"
            if [[ $first == @* ]]; then
                hosts=$second
            else
                hosts=$first
            fi

            [[ -n $hosts && $hosts != '|1|'* ]] || continue
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
        done < "$known"
    fi

    for file in "$config" /etc/ssh/ssh_config "${__kh_scan_files[@]}"; do
        [[ -n $file && -z ${watched_seen["$file"]+x} ]] || continue
        watched_seen["$file"]=1
        watched_files+=("$file")
    done

    __ssh_completion_config_files=("${watched_files[@]}")
    for file in "${__ssh_completion_config_files[@]}"; do
        if [[ -r $file ]]; then
            __ssh_completion_config_readable["$file"]=1
            __ssh_completion_config_content["$file"]=$(< "$file")
        else
            __ssh_completion_config_readable["$file"]=0
            __ssh_completion_config_content["$file"]=''
        fi
    done

    __ssh_completion_include_patterns=("${__kh_scan_include_patterns[@]}")
    for pattern in "${__ssh_completion_include_patterns[@]}"; do
        current=$(compgen -G "$pattern" || true)
        __ssh_completion_include_matches["$pattern"]=$current
    done

    if [[ -r $known ]]; then
        __ssh_completion_known_readable=1
        __ssh_completion_known_content=$(< "$known")
    else
        __ssh_completion_known_readable=0
        __ssh_completion_known_content=''
    fi
    __ssh_completion_cache_id="$known|$config"
}

__ssh_completion_cache_ensure() {
    local known=${1:-${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}}
    local config=${2:-${SSH_CONFIG_FILE:-$HOME/.ssh/config}}

    if ! __ssh_completion_cache_valid "$known" "$config"; then
        __ssh_completion_refresh "$known" "$config"
    fi
}
