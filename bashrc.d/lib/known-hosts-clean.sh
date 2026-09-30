#!/usr/bin/env bash

# known-hosts --clean
#
# Split out of lib/known-hosts.sh, which had grown to four concerns in one
# file. What is left there is the cache, the grouping model and the display,
# all of which ssh-nr and the completions build on; nothing outside this file
# uses anything defined here except ssh_known_hosts, which dispatches --clean
# to __kh_clean_run.
#
# Requires lib/ssh-config.sh and lib/known-hosts.sh.

declare -F __kh_parse_known_line >/dev/null || {
    printf 'known-hosts-clean.sh: lib/ssh-config.sh has to be sourced first.\n' >&2
    return 1
}
declare -F __kh_cache_invalidate >/dev/null || {
    printf 'known-hosts-clean.sh: lib/known-hosts.sh has to be sourced first.\n' >&2
    return 1
}

declare -A __kh_clean_seen=()
declare -A __kh_clean_target_checked=()
declare -A __kh_clean_target_keep=()
declare -A __kh_clean_target_mismatch=()
declare -A __kh_clean_target_unreachable=()
declare -A __kh_clean_target_stale=()
declare -A __kh_clean_target_reason=()
declare -A __kh_clean_endpoint_reachable=()
declare -A __kh_clean_endpoint_unreachable=()

__kh_clean_scan_type_for() {
    case $1 in
        ssh-ed25519)    printf '%s\n' 'ed25519' ;;
        ssh-rsa)        printf '%s\n' 'rsa' ;;
        ecdsa-sha2-*)   printf '%s\n' 'ecdsa' ;;
        ssh-ed25519-sk) printf '%s\n' 'ed25519-sk' ;;
        ecdsa-sk-*)     printf '%s\n' 'ecdsa-sk' ;;
        *) return 1 ;;
    esac
}

# Return:
#   0 = key matches
#   1 = key does not match / no longer present
#   2 = host unreachable / no key returned
#   3 = key type not supported
__kh_clean_check_entry() {
    local host=$1 port=$2 keytype=$3 stored_key=$4 timeout=$5
    local scan_type scanned current_key

    scan_type=$(__kh_clean_scan_type_for "$keytype") || return 3

    scanned=$(
        command ssh-keyscan \
            -T "$timeout" \
            -p "$port" \
            -t "$scan_type" \
            "$host" 2>/dev/null |
        awk -v type="$keytype" '$2 == type { print $3 }'
    )

    [[ -n $scanned ]] || return 2

    while IFS= read -r current_key; do
        [[ $current_key == "$stored_key" ]] && return 0
    done <<< "$scanned"

    return 1
}

__kh_clean_reset_state() {
    __kh_clean_seen=()
    __kh_clean_target_checked=()
    __kh_clean_target_keep=()
    __kh_clean_target_mismatch=()
    __kh_clean_target_unreachable=()
    __kh_clean_target_stale=()
    __kh_clean_target_reason=()
    __kh_clean_endpoint_reachable=()
    __kh_clean_endpoint_unreachable=()
}

# Records the result of a checkable known_hosts entry per lookup target.
# A target only counts as stale later if at least one entry was
# MISMATCH/UNREACHABLE and no entry for that target is kept.
__kh_clean_record_target_result() {
    local lookup=$1 result=$2

    [[ -n $lookup ]] || return 0
    __kh_clean_target_checked["$lookup"]=1

    case $result in
        0|3) __kh_clean_target_keep["$lookup"]=1 ;;
        1)   __kh_clean_target_mismatch["$lookup"]=1 ;;
        2)   __kh_clean_target_unreachable["$lookup"]=1 ;;
    esac
}

__kh_clean_finalize_targets() {
    local lookup reason

    for lookup in "${!__kh_clean_target_checked[@]}"; do
        [[ -z ${__kh_clean_target_keep["$lookup"]+x} ]] || continue
        [[ -n ${__kh_clean_target_mismatch["$lookup"]+x} ||
           -n ${__kh_clean_target_unreachable["$lookup"]+x} ]] || continue

        __kh_clean_target_stale["$lookup"]=1
        reason=''

        if [[ -n ${__kh_clean_target_mismatch["$lookup"]+x} ]]; then
            reason='KEY MISMATCH'
        fi
        if [[ -n ${__kh_clean_target_unreachable["$lookup"]+x} ]]; then
            if [[ -n $reason ]]; then
                reason+=' / UNREACHABLE'
            else
                reason='UNREACHABLE'
            fi
        fi

        __kh_clean_target_reason["$lookup"]=$reason
    done
}

# Writes a known_hosts line to the temporary file exactly once.
# Comments or differing whitespace outside the relevant fields do not affect
# duplicate detection.
# Return 10 means: exact duplicate, the line was deliberately not written.
__kh_clean_keep_line() {
    local line=$1 tmp=$2
    local marker hosts keytype stored_key identity

    # Keep incomplete entries unchanged.
    if ! __kh_parse_known_line "$line"; then
        printf '%s\n' "$line" >> "$tmp"
        return $?
    fi

    marker=$__kh_line_marker
    hosts=$__kh_line_hosts
    keytype=$__kh_line_keytype
    stored_key=$__kh_line_key

    if [[ -z $keytype || -z $stored_key ]]; then
        printf '%s\n' "$line" >> "$tmp"
        return $?
    fi

    identity="$marker $hosts $keytype $stored_key"

    if [[ -n ${__kh_clean_seen["$identity"]+x} ]]; then
        printf 'DUPLICATE -> REMOVE: %s %s\n' "$hosts" "$keytype"
        return 10
    fi

    __kh_clean_seen["$identity"]=1
    printf '%s\n' "$line" >> "$tmp"
}

# Resolves a concrete host alias the same way known-hosts does.
# Results:
#   __kh_clean_resolved_host    actual connection target
#   __kh_clean_resolved_port    effective port
#   __kh_clean_resolved_lookup  known_hosts lookup incl. HostKeyAlias/port
__kh_clean_resolve_alias() {
    local config=$1 alias=$2
    local resolved field value host='' port=22 keyalias=''

    __kh_clean_resolved_host=''
    __kh_clean_resolved_port=22
    __kh_clean_resolved_lookup=''

    __kh_ssh_config_dump "$config" "$alias" 1 || return 1
    resolved=$REPLY

    while read -r field value; do
        case $field in
            hostname)     host=$value ;;
            port)         port=$value ;;
            hostkeyalias) keyalias=$value ;;
        esac
    done <<< "$resolved"

    [[ -n $host ]] || return 1
    [[ $port =~ ^[0-9]+$ ]] || return 1

    __kh_lookup_key "$host" "$keyalias" "$port"
    __kh_clean_resolved_host=$host
    __kh_clean_resolved_port=$port
    __kh_clean_resolved_lookup=$REPLY
    return 0
}

# Checks a config target when known_hosts did not yield a reliable decision for
# it. Any host key returned by ssh-keyscan is enough; the actual key match is
# still verified through known_hosts. Results are cached per host/port.
# Return:
#   0 = reachable / at least one host key returned
#   2 = unreachable / no host key returned
__kh_clean_check_endpoint() {
    local host=$1 port=$2 timeout=$3
    local endpoint scanned

    endpoint="[$host]:$port"

    if [[ -n ${__kh_clean_endpoint_reachable["$endpoint"]+x} ]]; then
        return 0
    fi
    if [[ -n ${__kh_clean_endpoint_unreachable["$endpoint"]+x} ]]; then
        return 2
    fi

    scanned=$(
        command ssh-keyscan \
            -T "$timeout" \
            -p "$port" \
            "$host" 2>/dev/null
    )

    if [[ -n $scanned ]]; then
        __kh_clean_endpoint_reachable["$endpoint"]=1
        return 0
    fi

    __kh_clean_endpoint_unreachable["$endpoint"]=1
    return 2
}

# Splits a Host line of the SSH configuration into concrete aliases that are
# safe to edit. Nothing is rewritten for wildcards/negations/quotes.
# Result arrays:
#   __kh_clean_cfg_tokens       all host tokens
#   __kh_clean_cfg_keep_tokens  tokens that are not to be removed
#   __kh_clean_cfg_drop_tokens  tokens that are to be removed
# Globals:
#   __kh_clean_cfg_complex      1 for a complex Host line
__kh_clean_classify_host_line() {
    local config=$1 content=$2 timeout=$3
    local keyword token lookup host port
    local -a words=()

    __kh_clean_cfg_tokens=()
    __kh_clean_cfg_keep_tokens=()
    __kh_clean_cfg_drop_tokens=()
    __kh_clean_cfg_drop_lookups=()
    __kh_clean_cfg_drop_reasons=()
    __kh_clean_cfg_complex=0

    content=${content/=/ }
    read -r -a words <<< "$content"
    ((${#words[@]} >= 2)) || return 1

    keyword=${words[0],,}
    [[ $keyword == host ]] || return 1

    for token in "${words[@]:1}"; do
        __kh_clean_cfg_tokens+=("$token")

        # Only change simple, concrete host aliases automatically.
        if [[ -z $token || $token == '!'* ||
              $token == *'*'* || $token == *'?'* || $token == *'['* ||
              $token == *'"'* || $token == *"'"* ||
              $token == *[[:space:][:cntrl:]]* ]]; then
            __kh_clean_cfg_complex=1
            __kh_clean_cfg_keep_tokens+=("$token")
            continue
        fi

        if ! __kh_clean_resolve_alias "$config" "$token"; then
            # If ssh -G cannot evaluate the alias, it is kept for safety.
            __kh_clean_cfg_keep_tokens+=("$token")
            continue
        fi

        lookup=$__kh_clean_resolved_lookup
        host=$__kh_clean_resolved_host
        port=$__kh_clean_resolved_port

        if [[ -n ${__kh_clean_target_stale["$lookup"]+x} ]]; then
            __kh_clean_cfg_drop_tokens+=("$token")
            __kh_clean_cfg_drop_lookups+=("$lookup")
            __kh_clean_cfg_drop_reasons+=("${__kh_clean_target_reason["$lookup"]}")
            continue
        fi

        # If the target was judged from a checkable known_hosts entry and was
        # not marked stale, the config stays as it is. That applies in
        # particular to a valid or unsupported key type.
        if [[ -n ${__kh_clean_target_checked["$lookup"]+x} ]]; then
            __kh_clean_cfg_keep_tokens+=("$token")
            continue
        fi

        # For config targets without a checkable known_hosts entry (never
        # connected, or a hashed entry only) reachability is checked directly
        # against the actual HostName/port target.
        if __kh_clean_check_endpoint "$host" "$port" "$timeout"; then
            __kh_clean_cfg_keep_tokens+=("$token")
        else
            __kh_clean_cfg_drop_tokens+=("$token")
            __kh_clean_cfg_drop_lookups+=("$lookup")
            __kh_clean_cfg_drop_reasons+=('UNREACHABLE')
        fi
    done

    return 0
}

# Builds the cleaned version of the primary SSH configuration.
# Include files are deliberately left untouched.
__kh_clean_build_config() {
    local config=$1 tmp=$2 timeout=$3
    local line code content header_keyword indent comment
    local i j block_end changes=0
    local drop_index
    local -a lines=()

    __kh_clean_config_changes=0

    [[ -f $config && -r $config ]] || return 0

    while IFS= read -r line || [[ -n $line ]]; do
        lines+=("${line%$'\r'}")
    done < "$config"

    for ((i=0; i<${#lines[@]}; i++)); do
        line=${lines[$i]}
        code=${line%%#*}
        content=$code
        content=${content#"${content%%[![:space:]]*}"}
        header_keyword=${content%%[[:space:]=]*}
        header_keyword=${header_keyword,,}

        if [[ $header_keyword != host ]]; then
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        fi

        if ! __kh_clean_classify_host_line "$config" "$code" "$timeout"; then
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        fi

        ((${#__kh_clean_cfg_drop_tokens[@]})) || {
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        }

        if (( __kh_clean_cfg_complex )); then
            printf 'CONFIG  SKIP    complex Host line: %s\n' "$content"
            printf '%s\n' "$line" >> "$tmp" || return 1
            continue
        fi

        for ((drop_index=0; drop_index<${#__kh_clean_cfg_drop_tokens[@]}; drop_index++)); do
            printf 'CONFIG  REMOVE  %-32s -> %-35s %s\n' \
                "${__kh_clean_cfg_drop_tokens[$drop_index]}" \
                "${__kh_clean_cfg_drop_lookups[$drop_index]}" \
                "${__kh_clean_cfg_drop_reasons[$drop_index]}"
        done

        ((changes+=${#__kh_clean_cfg_drop_tokens[@]}))

        if ((${#__kh_clean_cfg_keep_tokens[@]} == 0)); then
            # Remove the whole Host block, not just the directives. That way
            # commented-out block options such as #IdentityFile or
            # #RemoteCommand are not left behind orphaned either.
            block_end=${#lines[@]}
            for ((j=i+1; j<${#lines[@]}; j++)); do
                code=${lines[$j]%%#*}
                content=$code
                content=${content#"${content%%[![:space:]]*}"}
                header_keyword=${content%%[[:space:]=]*}
                header_keyword=${header_keyword,,}
                if [[ $header_keyword == host || $header_keyword == match ]]; then
                    block_end=$j
                    break
                fi
            done

            i=$((block_end - 1))
            continue
        fi

        # Several concrete aliases on one Host line: remove only the stale
        # aliases and keep the block for the remaining ones.
        indent=${line%%[![:space:]]*}
        comment=''
        [[ $line == *'#'* ]] && comment=${line#*#}

        printf '%sHost' "$indent" >> "$tmp" || return 1
        for content in "${__kh_clean_cfg_keep_tokens[@]}"; do
            printf ' %s' "$content" >> "$tmp" || return 1
        done
        if [[ $line == *'#'* ]]; then
            printf ' #%s' "$comment" >> "$tmp" || return 1
        fi
        printf '\n' >> "$tmp" || return 1
    done

    __kh_clean_config_changes=$changes
    return 0
}

# Runs in a subshell, the same arrangement sshp() uses: a single EXIT trap then
# covers every error path and a Ctrl-C alike, instead of eight hand-placed
# "rm -f" calls that a new early return would silently forget.
#
# The price is that state set here does not reach the calling shell, which is
# why ssh_known_hosts drops the caches after a successful --apply.
__kh_clean_run() (
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local timeout=${SSH_KNOWN_HOSTS_CLEAN_TIMEOUT:-3}
    local apply=${1:-0}
    local tmp_known='' tmp_config=''
    local backup_known='' backup_config='' stamp
    local line hosts keytype stored_key host port result keep_rc
    local rc=0 known_changes=0 config_changes=0
    local config_exists=0

    [[ $timeout =~ ^[1-9][0-9]*$ ]] || {
        printf 'known-hosts: invalid timeout: %s\n' "$timeout" >&2
        return 2
    }

    [[ -f $known_hosts_file && -r $known_hosts_file ]] || {
        printf 'known-hosts: known_hosts not found or not readable: %s\n' \
            "$known_hosts_file" >&2
        return 1
    }

    if [[ -e $config ]]; then
        [[ -f $config && -r $config ]] || {
            printf 'known-hosts: SSH configuration not readable: %s\n' "$config" >&2
            return 1
        }
        config_exists=1
    fi

    if (( apply )); then
        [[ -w $known_hosts_file ]] || {
            printf 'known-hosts: known_hosts is not writable: %s\n' \
                "$known_hosts_file" >&2
            return 1
        }
        if (( config_exists )) && [[ ! -w $config ]]; then
            printf 'known-hosts: SSH configuration is not writable: %s\n' \
                "$config" >&2
            return 1
        fi
    fi

    command -v ssh-keyscan >/dev/null 2>&1 || {
        printf 'known-hosts: ssh-keyscan was not found.\n' >&2
        return 1
    }
    command -v ssh >/dev/null 2>&1 || {
        printf 'known-hosts: ssh was not found.\n' >&2
        return 1
    }
    command -v awk >/dev/null 2>&1 || {
        printf 'known-hosts: awk was not found.\n' >&2
        return 1
    }

    trap 'rm -f -- "$tmp_known" "$tmp_config"' EXIT HUP INT TERM

    tmp_known=$(mktemp) || {
        printf 'known-hosts: could not create the temporary file.\n' >&2
        return 1
    }
    if (( config_exists )); then
        tmp_config=$(mktemp) || {
            printf 'known-hosts: could not create the temporary config file.\n' >&2
            return 1
        }
    fi

    __kh_clean_reset_state

    # Always build the prospective known_hosts file without the entries that
    # are to be removed. In a dry run it is simply not written back.
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}

        if [[ $line =~ ^[[:space:]]*(#|$) ]]; then
            printf '%s\n' "$line" >> "$tmp_known" || { rc=1; break; }
            continue
        fi

        # A line the parser cannot make sense of is written back unchanged
        # rather than dropped: --apply must never lose data it did not judge.
        if ! __kh_parse_known_line "$line"; then
            printf 'SKIP    unparsable line\n'
            printf '%s\n' "$line" >> "$tmp_known" || { rc=1; break; }
            continue
        fi

        hosts=$__kh_line_hosts
        keytype=$__kh_line_keytype
        stored_key=$__kh_line_key

        if [[ -n $__kh_line_marker ]]; then
            printf '%s\n' 'SKIP    marker entry'

            # A simple marker entry for the same lookup target is kept on
            # purpose and therefore prevents the config from being removed
            # automatically.
            if (( ! __kh_line_hashed )) &&
               [[ $hosts != *','* && $hosts != *'*'* &&
                  $hosts != *'?'* && $hosts != *'!'* ]]; then
                __kh_clean_target_keep["$hosts"]=1
            fi

            __kh_clean_keep_line "$line" "$tmp_known"
            keep_rc=$?
            (( keep_rc == 10 )) && ((known_changes+=1))
            (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
            continue
        fi

        if (( __kh_line_hashed )); then
            printf '%s\n' 'SKIP    hashed entry'
            __kh_clean_keep_line "$line" "$tmp_known"
            keep_rc=$?
            (( keep_rc == 10 )) && ((known_changes+=1))
            (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
            continue
        fi

        if [[ $hosts == *','* ||
              $hosts == *'*'* ||
              $hosts == *'?'* ||
              $hosts == *'!'* ]]; then
            printf 'SKIP    complex host: %s\n' "$hosts"
            __kh_clean_keep_line "$line" "$tmp_known"
            keep_rc=$?
            (( keep_rc == 10 )) && ((known_changes+=1))
            (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
            continue
        fi

        __kh_split_host_port "$hosts"
        host=$__kh_host
        port=$__kh_port

        printf 'CHECK   %-35s %-28s ' "$host:$port" "$keytype"

        __kh_clean_check_entry "$host" "$port" "$keytype" "$stored_key" "$timeout"
        result=$?
        __kh_clean_record_target_result "$hosts" "$result"

        case $result in
            0)
                printf '%s\n' 'OK'
                __kh_clean_keep_line "$line" "$tmp_known"
                keep_rc=$?
                (( keep_rc == 10 )) && ((known_changes+=1))
                (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
                ;;
            1)
                printf '%s\n' 'KEY MISMATCH -> REMOVE'
                ((known_changes+=1))
                ;;
            2)
                printf '%s\n' 'UNREACHABLE -> REMOVE'
                ((known_changes+=1))
                ;;
            3)
                printf '%s\n' 'UNSUPPORTED KEY TYPE -> KEEP'
                __kh_clean_keep_line "$line" "$tmp_known"
                keep_rc=$?
                (( keep_rc == 10 )) && ((known_changes+=1))
                (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
                ;;
        esac
    done < "$known_hosts_file"

    if (( rc == 0 )); then
        __kh_clean_finalize_targets

        if (( config_exists )); then
            printf '\nChecking the SSH configuration: %s\n' "$config"
            __kh_clean_build_config "$config" "$tmp_config" "$timeout" || rc=1
            config_changes=$__kh_clean_config_changes
        fi
    fi

    if (( rc != 0 )); then
        printf 'known-hosts: could not write the temporary output.\n' >&2
        return "$rc"
    fi

    if (( apply )); then
        stamp=$(date +%Y%m%d-%H%M%S)

        if (( known_changes > 0 )); then
            backup_known="${known_hosts_file}.bak.$stamp"
            if ! command cp -- "$known_hosts_file" "$backup_known"; then
                printf 'known-hosts: could not create the known_hosts backup.\n' >&2
                return 1
            fi
        fi

        if (( config_changes > 0 )); then
            backup_config="${config}.bak.$stamp"
            if ! command cp -- "$config" "$backup_config"; then
                printf 'known-hosts: could not create the config backup.\n' >&2
                return 1
            fi
        fi

        if (( known_changes > 0 )); then
            if ! command cat -- "$tmp_known" > "$known_hosts_file"; then
                [[ -n $backup_known ]] && command cp -- "$backup_known" "$known_hosts_file" 2>/dev/null || true
                printf 'known-hosts: could not write known_hosts; the backup was restored.\n' >&2
                return 1
            fi
        fi

        if (( config_changes > 0 )); then
            if ! command cat -- "$tmp_config" > "$config"; then
                [[ -n $backup_known ]] && command cp -- "$backup_known" "$known_hosts_file" 2>/dev/null || true
                [[ -n $backup_config ]] && command cp -- "$backup_config" "$config" 2>/dev/null || true
                printf 'known-hosts: could not write the SSH configuration; the backups were restored.\n' >&2
                return 1
            fi
        fi

        printf '\nCleanup finished.\n'
        printf 'known_hosts: %d change(s)\n' "$known_changes"
        printf 'SSH config:  %d alias change(s)\n' "$config_changes"
        [[ -z $backup_known ]] || printf 'Backup known_hosts: %s\n' "$backup_known"
        [[ -z $backup_config ]] || printf 'Backup SSH config:  %s\n' "$backup_config"
    else
        printf '\nDRY RUN - no files were changed.\n'
        printf 'known_hosts: %d change(s) would be made\n' "$known_changes"
        printf 'SSH config:  %d alias change(s) would be made\n\n' "$config_changes"
        printf 'To actually clean up:\n'
        printf '  known-hosts --clean --apply\n'
    fi

    return 0
)
