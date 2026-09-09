#!/usr/bin/env bash

# Shared SSH config scanner for known-hosts and its completion.
# The result arrays are reset before every scan.
declare -a __kh_scan_aliases=()
declare -a __kh_scan_files=()
declare -a __kh_scan_include_patterns=()
declare -A __kh_scan_alias_seen=()
declare -A __kh_scan_file_seen=()
declare -A __kh_scan_include_seen=()

# Explicit user assignments from concrete Host blocks of the user config.
# Wildcard/negation blocks such as "Host *" deliberately do not count as direct.
declare -A __kh_scan_alias_direct_user=()
declare -A __kh_scan_target_direct_user=()

__kh_scan_reset() {
    __kh_scan_aliases=()
    __kh_scan_files=()
    __kh_scan_include_patterns=()
    __kh_scan_alias_seen=()
    __kh_scan_file_seen=()
    __kh_scan_include_seen=()
    __kh_scan_alias_direct_user=()
    __kh_scan_target_direct_user=()
}

# Collects concrete host aliases and follows Include directives recursively.
# Supports relative paths, absolute paths, ~/ and globs.
# Tokens containing %, $ or whitespace are deliberately not evaluated.
__kh_scan_file() {
    local file=$1 base=$2 track_includes=${3:-0} track_direct_users=${4:-0}
    local line keyword token match alias
    local stanza_hostname='' stanza_user=''
    local -a words stanza_aliases=()

    [[ -r $file && -z ${__kh_scan_file_seen["$file"]+x} ]] || return 0

    __kh_scan_file_seen["$file"]=1
    __kh_scan_files+=("$file")

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line%%#*}
        line=${line/=/ }
        read -r -a words <<< "$line"
        ((${#words[@]})) || continue

        keyword=${words[0],,}

        case $keyword in
            host|match)
                stanza_aliases=()
                stanza_hostname=''
                stanza_user=''
                ;;
        esac

        for token in "${words[@]:1}"; do
            token=${token#\"}
            token=${token%\"}

            case $keyword in
                host)
                    [[ -n $token && $token != -* &&
                       $token != *['*?!']* &&
                       $token != *[[:space:][:cntrl:]]* ]] || continue

                    if [[ -z ${__kh_scan_alias_seen["$token"]+x} ]]; then
                        __kh_scan_alias_seen["$token"]=1
                        __kh_scan_aliases+=("$token")
                    fi
                    (( track_direct_users )) && stanza_aliases+=("$token")
                    ;;

                hostname)
                    (( track_direct_users )) || continue
                    [[ -z $stanza_hostname ]] || continue
                    [[ -n $token && $token != *['%$*?!']* &&
                       $token != *[[:space:][:cntrl:]]* ]] || continue

                    stanza_hostname=$token
                    if [[ -n $stanza_user &&
                          -z ${__kh_scan_target_direct_user["$stanza_hostname"]+x} ]]; then
                        __kh_scan_target_direct_user["$stanza_hostname"]=$stanza_user
                    fi
                    ;;

                user)
                    (( track_direct_users )) || continue
                    ((${#stanza_aliases[@]})) || continue
                    [[ -z $stanza_user ]] || continue

                    stanza_user=$token
                    for alias in "${stanza_aliases[@]}"; do
                        if [[ -z ${__kh_scan_alias_direct_user["$alias"]+x} ]]; then
                            __kh_scan_alias_direct_user["$alias"]=$stanza_user
                        fi
                    done

                    if [[ -n $stanza_hostname &&
                          -z ${__kh_scan_target_direct_user["$stanza_hostname"]+x} ]]; then
                        __kh_scan_target_direct_user["$stanza_hostname"]=$stanza_user
                    fi
                    ;;

                include)
                    [[ $token != *['%$']* ]] || continue

                    case $token in
                        '~/'*) token="$HOME/${token:2}" ;;
                        /*) ;;
                        *) token="$base/$token" ;;
                    esac

                    if (( track_includes )) &&
                       [[ -z ${__kh_scan_include_seen["$token"]+x} ]]; then
                        __kh_scan_include_seen["$token"]=1
                        __kh_scan_include_patterns+=("$token")
                    fi

                    while IFS= read -r match; do
                        [[ -z $match ]] || __kh_scan_file "$match" "$base" "$track_includes" "$track_direct_users"
                    done <<< "$(compgen -G "$token" || true)"
                    ;;
            esac
        done
    done < "$file"
}

# Scans the given user configuration plus the system-wide SSH config.
__kh_scan_configs() {
    local config=$1 track_includes=${2:-0}

    __kh_scan_reset
    __kh_scan_file "$config" "$HOME/.ssh" "$track_includes" 1
    __kh_scan_file /etc/ssh/ssh_config /etc/ssh "$track_includes" 0
}
