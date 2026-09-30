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

# ---------------------------------------------------------------------------
# Shared known_hosts and "ssh -G" primitives
#
# These used to be copy-pasted into every command that reads known_hosts or
# evaluates the SSH configuration: known-hosts, its --clean pass, the grouping
# model and both resolvers. One implementation means one place to fix a parser
# bug, and CRLF configs, marker entries and hashed entries behave identically
# everywhere.
# ---------------------------------------------------------------------------

# __kh_parse_known_line LINE
#
# Splits one known_hosts line into its fields. Returns 1 for comments, blank
# lines and lines without a host field, so callers can "|| continue".
#
#   __kh_line_marker    @cert-authority / @revoked, empty when absent
#   __kh_line_hosts     the comma-separated host field, verbatim
#   __kh_line_keytype   ssh-ed25519, ecdsa-sha2-nistp256, ...
#   __kh_line_key       the key material
#   __kh_line_hashed    1 for a |1|... entry, whose hostname cannot be recovered
__kh_line_marker=''
__kh_line_hosts=''
__kh_line_keytype=''
__kh_line_key=''
__kh_line_hashed=0

__kh_parse_known_line() {
    local line=${1%$'\r'} first second third fourth

    __kh_line_marker=''
    __kh_line_hosts=''
    __kh_line_keytype=''
    __kh_line_key=''
    __kh_line_hashed=0

    [[ $line =~ ^[[:space:]]*(#|$) ]] && return 1

    read -r first second third fourth _ <<< "$line"

    if [[ $first == @* ]]; then
        __kh_line_marker=$first
        __kh_line_hosts=$second
        __kh_line_keytype=$third
        __kh_line_key=$fourth
    else
        __kh_line_hosts=$first
        __kh_line_keytype=$second
        __kh_line_key=$third
    fi

    [[ -n $__kh_line_hosts ]] || return 1
    [[ $__kh_line_hosts != '|1|'* ]] || __kh_line_hashed=1
    return 0
}

# __kh_split_host_port TOKEN
#
# Unwraps the [host]:port form used by known_hosts and by HostKeyAlias
# lookups. A bare token yields the token itself and port 22.
#
#   __kh_host   the host part
#   __kh_port   the port, 22 when the token carries none
__kh_host=''
__kh_port=22

__kh_split_host_port() {
    if [[ $1 =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        __kh_host=${BASH_REMATCH[1]}
        __kh_port=${BASH_REMATCH[2]}
    else
        __kh_host=$1
        __kh_port=22
    fi
}

# __kh_ssh_config_dump CONFIG TARGET [QUIET]
#
# Runs "ssh -G" for one target and leaves the output in REPLY. -G opens no
# connection, but it does evaluate Match exec rules from the configuration.
# The default config path is passed without -F so ssh applies its own
# precedence; any other path is passed explicitly.
#
# QUIET=1 discards ssh's stderr, for callers that treat a failure as "skip".
# The exit status is ssh's own.
__kh_ssh_config_dump() {
    local config=$1 target=$2 quiet=${3:-0}
    local -a command=(command ssh -G -T)

    [[ $config == "$HOME/.ssh/config" ]] || command+=(-F "$config")
    command+=("$target")

    if (( quiet )); then
        REPLY=$("${command[@]}" 2>/dev/null)
    else
        REPLY=$("${command[@]}")
    fi
}

# __kh_ssh_config_field DUMP FIELD
#
# Reads one keyword out of an "ssh -G" dump into REPLY. Returns 1 when the
# keyword is absent.
__kh_ssh_config_field() {
    local dump=$1 wanted=$2 field value

    while read -r field value; do
        [[ $field == "$wanted" ]] || continue
        REPLY=$value
        return 0
    done <<< "$dump"

    REPLY=''
    return 1
}

# __kh_lookup_key HOSTNAME HOSTKEYALIAS PORT
#
# Derives the name a known_hosts entry is stored under, into REPLY:
# HostKeyAlias wins over HostName unless it is unset or "none", and a
# non-default port wraps the result as [key]:port.
__kh_lookup_key() {
    local host=$1 keyalias=$2 port=$3

    REPLY=$host
    [[ -z $keyalias || $keyalias == none ]] || REPLY=$keyalias
    [[ $port == 22 ]] || REPLY="[$REPLY]:$port"
}
