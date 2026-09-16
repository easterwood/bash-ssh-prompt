#!/usr/bin/env bash

# Host mapping cache for this shell.
declare -A __kh_rows=()
# Effective user for direct known_hosts targets without an assigned alias.
declare -A __kh_target_users=()
# 1 if the user is set directly in a concrete Host block of the user config.
declare -A __kh_target_user_explicit=()
__kh_cache_id=''
__kh_known_content=''

__kh_cache_invalidate() {
    __kh_cache_id=''
    __kh_rows=()
    __kh_target_users=()
    __kh_target_user_explicit=()
    declare -F __kh_groups_reset >/dev/null && __kh_groups_reset
}

__kh_refresh() {
    local known=$1 config=$2
    local alias resolved field value host user port keyalias lookup hits n rc row_token user_explicit
    local -A row_seen=()

    __kh_cache_invalidate
    __kh_scan_configs "$config" 0

    for alias in "${__kh_scan_aliases[@]}"; do
        # -G does not open an SSH session. Configured Match exec rules may run.
        if [[ $config == "$HOME/.ssh/config" ]]; then
            resolved=$(command ssh -G -T "$alias") || {
                printf 'known-hosts: could not evaluate the SSH configuration for alias %q.\n' "$alias" >&2
                return 1
            }
        else
            resolved=$(command ssh -G -T -F "$config" "$alias") || {
                printf 'known-hosts: could not evaluate the SSH configuration for alias %q.\n' "$alias" >&2
                return 1
            }
        fi

        host=''
        user=''
        port=22
        keyalias=''

        while read -r field value; do
            case $field in
                hostname) host=$value ;;
                user) user=$value ;;
                port) port=$value ;;
                hostkeyalias) keyalias=$value ;;
            esac
        done <<< "$resolved"

        [[ -n $host && -n $user ]] || continue

        lookup=$host
        [[ -z $keyalias || $keyalias == none ]] || lookup=$keyalias
        [[ $port == 22 ]] || lookup="[$lookup]:$port"

        rc=0
        hits=$(command ssh-keygen -F "$lookup" -f "$known") || rc=$?
        ((rc <= 1)) || return "$rc"

        while IFS= read -r value; do
            if [[ $value =~ ^#[[:space:]].*[[:space:]]line[[:space:]]([0-9]+)[[:space:]]*$ ]]; then
                n=${BASH_REMATCH[1]}
                row_token="$n"$'\x1f'"$alias"$'\x1f'"$user"$'\x1f'"$lookup"
                [[ -z ${row_seen["$row_token"]+x} ]] || continue
                row_seen["$row_token"]=1
                user_explicit=0
                if [[ ${__kh_scan_alias_direct_user["$alias"]-} == "$user" ]]; then
                    user_explicit=1
                fi
                __kh_rows[$n]+="$alias"$'\t'"$user"$'\t'"$lookup"$'\t'"$user_explicit"$'\n'
            fi
        done <<< "$hits"
    done

    # For known_hosts entries without an explicit alias assignment, still
    # determine the effective user from the SSH configuration. That way Host *
    # defaults and host wildcards apply as well. The target host itself is not
    # printed as an alias.
    local kh_line kh_line_number=0 first second raw_hosts raw_host effective_user
    while IFS= read -r kh_line || [[ -n $kh_line ]]; do
        ((kh_line_number+=1))
        [[ $kh_line =~ ^[[:space:]]*(#|$) ]] && continue

        read -r first second _ <<< "$kh_line"
        if [[ $first == @* ]]; then
            raw_hosts=$second
        else
            raw_hosts=$first
        fi

        [[ -n $raw_hosts ]] || continue
        [[ -z ${__kh_rows[$kh_line_number]-} ]] || continue
        [[ $raw_hosts != '|1|'* ]] || continue
        [[ $raw_hosts != *','* &&
           $raw_hosts != *'*'* &&
           $raw_hosts != *'?'* &&
           $raw_hosts != *'!'* ]] || continue
        [[ -z ${__kh_target_users["$raw_hosts"]+x} ]] || continue

        raw_host=$raw_hosts
        if [[ $raw_hosts =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
            raw_host=${BASH_REMATCH[1]}
        fi

        resolved=''
        if [[ $config == "$HOME/.ssh/config" ]]; then
            resolved=$(command ssh -G -T "$raw_host" 2>/dev/null) || true
        else
            resolved=$(command ssh -G -T -F "$config" "$raw_host" 2>/dev/null) || true
        fi

        effective_user=''
        while read -r field value; do
            [[ $field == user ]] || continue
            effective_user=$value
            break
        done <<< "$resolved"

        __kh_target_users["$raw_hosts"]=${effective_user:--}
        __kh_target_user_explicit["$raw_hosts"]=0

        # Do not mark it when exactly this effective user is assigned
        # explicitly to a concrete host/alias or its literal HostName. A user
        # coming from "Host *" or wildcard blocks stays inherited.
        if [[ -n $effective_user &&
              ( ${__kh_scan_alias_direct_user["$raw_host"]-} == "$effective_user" ||
                ${__kh_scan_target_direct_user["$raw_host"]-} == "$effective_user" ) ]]; then
            __kh_target_user_explicit["$raw_hosts"]=1
        fi
    done < "$known"

    __kh_cache_id="$known|$config"
    __kh_known_content=$(< "$known")
}

__kh_cache_ensure() {
    local known=$1 config=$2

    if [[ $__kh_cache_id != "$known|$config" ||
          $__kh_known_content != "$(< "$known")" ]]; then
        __kh_refresh "$known" "$config"
    fi
}

# Shared, aggregated model for the display and for login by target number.
declare -a __kh_group_alias=()
declare -a __kh_group_target=()
declare -a __kh_group_user=()
declare -a __kh_group_user_explicit=()
declare -a __kh_group_lines=()
declare -a __kh_group_keys=()
__kh_group_count=0

__kh_groups_reset() {
    __kh_group_alias=()
    __kh_group_target=()
    __kh_group_user=()
    __kh_group_user_explicit=()
    __kh_group_lines=()
    __kh_group_keys=()
    __kh_group_count=0
}

# Builds exactly the same groups known-hosts displays. The group order also
# defines the stable target number for the current state of the file.
__kh_groups_build() {
    local known_hosts_file=$1 config=$2
    local line line_number=0 first second third fourth remainder
    local marker hosts key_type key display_hosts target
    local rows alias user lookup user_explicit
    local group_key seen_token gid
    local sep=$'\x1f'
    local -A group_id=() key_seen=() line_seen=()

    __kh_groups_reset
    __kh_cache_ensure "$known_hosts_file" "$config" || return

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number+=1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue

        read -r first second third fourth remainder <<< "$line"
        marker=''

        if [[ $first == @* ]]; then
            marker=$first
            hosts=$second
            key_type=$third
            key=$fourth
        else
            hosts=$first
            key_type=$second
            key=$third
        fi

        [[ -n $hosts && -n $key_type && -n $key ]] || continue

        if [[ $hosts == '|1|'* ]]; then
            display_hosts='[hashed hostname]'
        else
            display_hosts=$hosts
        fi
        [[ -z $marker ]] || display_hosts="$marker $display_hosts"

        key_type=${key_type#ssh-}
        key_type=${key_type^^}
        rows=${__kh_rows[$line_number]-}

        if [[ -n $rows ]]; then
            while IFS=$'\t' read -r alias user lookup user_explicit; do
                [[ -n $alias ]] || continue

                target=$lookup
                [[ -z $marker || $target == "$marker "* ]] || target="$marker $target"

                group_key="A$sep$alias$sep$target$sep$user"
                if [[ -z ${group_id["$group_key"]+x} ]]; then
                    gid=$__kh_group_count
                    ((__kh_group_count+=1))
                    group_id["$group_key"]=$gid
                    __kh_group_alias[$gid]=$alias
                    __kh_group_target[$gid]=$target
                    __kh_group_user[$gid]=$user
                    __kh_group_user_explicit[$gid]=${user_explicit:-0}
                    __kh_group_lines[$gid]=''
                    __kh_group_keys[$gid]=''
                else
                    gid=${group_id["$group_key"]}
                fi

                seen_token="$gid$sep$line_number"
                if [[ -z ${line_seen["$seen_token"]+x} ]]; then
                    line_seen["$seen_token"]=1
                    if [[ -n ${__kh_group_lines[$gid]} ]]; then
                        __kh_group_lines[$gid]+=",$line_number"
                    else
                        __kh_group_lines[$gid]=$line_number
                    fi
                fi

                seen_token="$gid$sep$key_type"
                if [[ -z ${key_seen["$seen_token"]+x} ]]; then
                    key_seen["$seen_token"]=1
                    if [[ -n ${__kh_group_keys[$gid]} ]]; then
                        __kh_group_keys[$gid]+=", $key_type"
                    else
                        __kh_group_keys[$gid]=$key_type
                    fi
                fi
            done <<< "$rows"
        else
            alias='-'
            user=${__kh_target_users["$hosts"]:--}
            user_explicit=${__kh_target_user_explicit["$hosts"]:-0}
            target=$display_hosts
            group_key="U$sep$marker$sep$hosts"

            if [[ -z ${group_id["$group_key"]+x} ]]; then
                gid=$__kh_group_count
                ((__kh_group_count+=1))
                group_id["$group_key"]=$gid
                __kh_group_alias[$gid]=$alias
                __kh_group_target[$gid]=$target
                __kh_group_user[$gid]=$user
                __kh_group_user_explicit[$gid]=${user_explicit:-0}
                __kh_group_lines[$gid]=''
                __kh_group_keys[$gid]=''
            else
                gid=${group_id["$group_key"]}
            fi

            seen_token="$gid$sep$line_number"
            if [[ -z ${line_seen["$seen_token"]+x} ]]; then
                line_seen["$seen_token"]=1
                if [[ -n ${__kh_group_lines[$gid]} ]]; then
                    __kh_group_lines[$gid]+=",$line_number"
                else
                    __kh_group_lines[$gid]=$line_number
                fi
            fi

            seen_token="$gid$sep$key_type"
            if [[ -z ${key_seen["$seen_token"]+x} ]]; then
                key_seen["$seen_token"]=1
                if [[ -n ${__kh_group_keys[$gid]} ]]; then
                    __kh_group_keys[$gid]+=", $key_type"
                else
                    __kh_group_keys[$gid]=$key_type
                fi
            fi
        fi
    done < "$known_hosts_file"
}

# ---------------------------------------------------------------------------
# known-hosts --clean
#
# Checks non-hashed known_hosts entries with ssh-keyscan and removes the
# matching stale host aliases from the primary SSH configuration. Dry run by
# default; with --apply both files are written after backups have been made.
# Include files of the SSH configuration are left untouched.
# ---------------------------------------------------------------------------

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
    local marker='' hosts keytype stored_key rest identity

    read -r hosts keytype stored_key rest <<< "$line"

    if [[ $hosts == @* ]]; then
        read -r marker hosts keytype stored_key rest <<< "$line"
    fi

    # Keep incomplete entries unchanged.
    if [[ -z $hosts || -z $keytype || -z $stored_key ]]; then
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

    if [[ $config == "$HOME/.ssh/config" ]]; then
        resolved=$(command ssh -G -T "$alias" 2>/dev/null) || return 1
    else
        resolved=$(command ssh -G -T -F "$config" "$alias" 2>/dev/null) || return 1
    fi

    while read -r field value; do
        case $field in
            hostname)     host=$value ;;
            port)         port=$value ;;
            hostkeyalias) keyalias=$value ;;
        esac
    done <<< "$resolved"

    [[ -n $host ]] || return 1
    [[ $port =~ ^[0-9]+$ ]] || return 1

    __kh_clean_resolved_host=$host
    __kh_clean_resolved_port=$port
    __kh_clean_resolved_lookup=$host
    [[ -z $keyalias || $keyalias == none ]] || __kh_clean_resolved_lookup=$keyalias
    [[ $port == 22 ]] || __kh_clean_resolved_lookup="[$__kh_clean_resolved_lookup]:$port"
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

__kh_clean_run() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local timeout=${SSH_KNOWN_HOSTS_CLEAN_TIMEOUT:-3}
    local apply=${1:-0}
    local tmp_known='' tmp_config=''
    local backup_known='' backup_config='' stamp
    local line hosts keytype stored_key rest host port result keep_rc
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

    tmp_known=$(mktemp) || {
        printf 'known-hosts: could not create the temporary file.\n' >&2
        return 1
    }
    if (( config_exists )); then
        tmp_config=$(mktemp) || {
            rm -f -- "$tmp_known"
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

        if [[ $line == @* ]]; then
            local marker_hosts marker_keytype marker_key marker_rest marker_name
            read -r marker_name marker_hosts marker_keytype marker_key marker_rest <<< "$line"
            printf '%s\n' 'SKIP    marker entry'

            # A simple marker entry for the same lookup target is kept on
            # purpose and therefore prevents the config from being removed
            # automatically.
            if [[ -n $marker_hosts && $marker_hosts != '|1|'* &&
                  $marker_hosts != *','* && $marker_hosts != *'*'* &&
                  $marker_hosts != *'?'* && $marker_hosts != *'!'* ]]; then
                __kh_clean_target_keep["$marker_hosts"]=1
            fi

            __kh_clean_keep_line "$line" "$tmp_known"
            keep_rc=$?
            (( keep_rc == 10 )) && ((known_changes+=1))
            (( keep_rc == 0 || keep_rc == 10 )) || { rc=1; break; }
            continue
        fi

        read -r hosts keytype stored_key rest <<< "$line"

        if [[ $hosts == '|1|'* ]]; then
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

        host=$hosts
        port=22

        if [[ $hosts =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[2]}
        fi

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
        rm -f -- "$tmp_known" "$tmp_config"
        printf 'known-hosts: could not write the temporary output.\n' >&2
        return "$rc"
    fi

    if (( apply )); then
        stamp=$(date +%Y%m%d-%H%M%S)

        if (( known_changes > 0 )); then
            backup_known="${known_hosts_file}.bak.$stamp"
            if ! command cp -- "$known_hosts_file" "$backup_known"; then
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts: could not create the known_hosts backup.\n' >&2
                return 1
            fi
        fi

        if (( config_changes > 0 )); then
            backup_config="${config}.bak.$stamp"
            if ! command cp -- "$config" "$backup_config"; then
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts: could not create the config backup.\n' >&2
                return 1
            fi
        fi

        if (( known_changes > 0 )); then
            if ! command cat -- "$tmp_known" > "$known_hosts_file"; then
                [[ -n $backup_known ]] && command cp -- "$backup_known" "$known_hosts_file" 2>/dev/null || true
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts: could not write known_hosts; the backup was restored.\n' >&2
                return 1
            fi
        fi

        if (( config_changes > 0 )); then
            if ! command cat -- "$tmp_config" > "$config"; then
                [[ -n $backup_known ]] && command cp -- "$backup_known" "$known_hosts_file" 2>/dev/null || true
                [[ -n $backup_config ]] && command cp -- "$backup_config" "$config" 2>/dev/null || true
                rm -f -- "$tmp_known" "$tmp_config"
                printf 'known-hosts: could not write the SSH configuration; the backups were restored.\n' >&2
                return 1
            fi
        fi

        rm -f -- "$tmp_known" "$tmp_config"

        if (( known_changes > 0 || config_changes > 0 )); then
            declare -F __kh_cache_invalidate >/dev/null && __kh_cache_invalidate
            declare -F __ssh_completion_cache_invalidate >/dev/null && __ssh_completion_cache_invalidate
        fi

        printf '\nCleanup finished.\n'
        printf 'known_hosts: %d change(s)\n' "$known_changes"
        printf 'SSH config:  %d alias change(s)\n' "$config_changes"
        [[ -z $backup_known ]] || printf 'Backup known_hosts: %s\n' "$backup_known"
        [[ -z $backup_config ]] || printf 'Backup SSH config:  %s\n' "$backup_config"
    else
        rm -f -- "$tmp_known" "$tmp_config"
        printf '\nDRY RUN - no files were changed.\n'
        printf 'known_hosts: %d change(s) would be made\n' "$known_changes"
        printf 'SSH config:  %d alias change(s) would be made\n\n' "$config_changes"
        printf 'To actually clean up:\n'
        printf '  known-hosts --clean --apply\n'
    fi

    return 0
}

__kh_usage() {
    cat <<'EOF_USAGE'
Usage: known-hosts [--lines] [--refresh] [FILTER]
       known-hosts --fingerprints
       known-hosts --clean [--apply]

  --lines         Show the known_hosts line numbers
  --refresh       Discard the cache and re-read the data
  --fingerprints  Show the original ssh-keygen fingerprints
  --clean         Check the entries with ssh-keyscan and report stale ones
  --apply         Only with --clean: write the cleaned files
  --help, -h      Show this help

FILTER is a substring and ignores case. Name, target, user, keys and line
numbers are searched.

--clean checks non-hashed known_hosts entries with ssh-keyscan and removes the
matching stale host aliases from the primary SSH configuration. Without --apply
it only shows what would be removed; with --apply, backups are created before
any change.

A config alias is removed when its resolved known_hosts target is stale after
the key check. If there is no checkable known_hosts entry for the alias,
HostName/port is checked directly with ssh-keyscan and an unreachable target is
removed as well. Complex host patterns and include files are not changed
automatically.

Environment variables:
  SSH_KNOWN_HOSTS_FILE           Path to known_hosts
  SSH_CONFIG_FILE                Primary SSH configuration
  SSH_KNOWN_HOSTS_CLEAN_TIMEOUT  ssh-keyscan timeout in seconds (default: 3)
EOF_USAGE
}

# Exactly one row is printed per alias/target/user.
# Multiple known_hosts lines and key types are merged.
# NR is the unique target number used by ssh-nr.
ssh_known_hosts() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local filter=''
    local show_lines=0 refresh=0 fingerprints=0 clean=0 apply=0
    local arg search filter_lc gid nr found=0
    local -a selected_ids=()
    local w_nr=2 w_line=5 w_target=4 w_alias=5 w_host=5 w_user=8

    while (( $# )); do
        arg=$1
        shift

        case $arg in
            --lines)
                show_lines=1
                ;;
            --refresh)
                refresh=1
                ;;
            --fingerprints)
                fingerprints=1
                ;;
            --clean)
                clean=1
                ;;
            --apply)
                apply=1
                ;;
            --help|-h)
                __kh_usage
                return 0
                ;;
            --)
                if (( $# > 1 )); then
                    printf 'known-hosts: only one FILTER is allowed.\n' >&2
                    return 2
                fi
                if (( $# == 1 )); then
                    [[ -z $filter ]] || {
                        printf 'known-hosts: only one FILTER is allowed.\n' >&2
                        return 2
                    }
                    filter=$1
                    shift
                fi
                ;;
            -*)
                printf 'known-hosts: unknown option: %s\n' "$arg" >&2
                __kh_usage >&2
                return 2
                ;;
            *)
                if [[ -n $filter ]]; then
                    printf 'known-hosts: only one FILTER is allowed.\n' >&2
                    return 2
                fi
                filter=$arg
                ;;
        esac
    done

    if (( apply && ! clean )); then
        printf 'known-hosts: --apply is only valid together with --clean.\n' >&2
        return 2
    fi

    if (( clean )); then
        if (( show_lines || refresh || fingerprints )) || [[ -n $filter ]]; then
            printf 'known-hosts: --clean cannot be combined with FILTER, --lines, --refresh or --fingerprints.\n' >&2
            return 2
        fi
        __kh_clean_run "$apply"
        return $?
    fi

    [[ -r $known_hosts_file ]] || {
        printf 'known-hosts: %s is missing or not readable.\n' "$known_hosts_file" >&2
        return 1
    }

    if (( fingerprints )); then
        if (( show_lines || refresh )) || [[ -n $filter ]]; then
            printf 'known-hosts: --fingerprints cannot be combined with FILTER, --lines or --refresh.\n' >&2
            return 2
        fi
        ssh-keygen -l -E sha256 -f "$known_hosts_file"
        return $?
    fi

    if (( refresh )); then
        __kh_cache_invalidate
        __kh_groups_reset
        __ssh_completion_cache_invalidate
        declare -F __ssh_resolve_ips_cache_invalidate >/dev/null && __ssh_resolve_ips_cache_invalidate
        declare -F __ssh_resolve_hosts_cache_invalidate >/dev/null && __ssh_resolve_hosts_cache_invalidate
    fi

    __kh_groups_build "$known_hosts_file" "$config" || return
    filter_lc=${filter,,}

    for ((gid=0; gid<__kh_group_count; gid++)); do
        nr=$((gid + 1))
        search="$nr ${__kh_group_alias[$gid]} ${__kh_group_target[$gid]} ${__kh_group_user[$gid]} ${__kh_group_keys[$gid]} ${__kh_group_lines[$gid]}"
        [[ -z $filter || ${search,,} == *"$filter_lc"* ]] || continue

        selected_ids+=("$gid")
        found=1

        ((${#nr} > w_nr)) && w_nr=${#nr}
        if (( show_lines )); then
            ((${#__kh_group_lines[$gid]} > w_line)) && w_line=${#__kh_group_lines[$gid]}
        fi
        ((${#__kh_group_alias[$gid]}  > w_alias))  && w_alias=${#__kh_group_alias[$gid]}
        ((${#__kh_group_target[$gid]} > w_target)) && w_target=${#__kh_group_target[$gid]}
        ((${#__kh_group_user[$gid]}   > w_user))   && w_user=${#__kh_group_user[$gid]}
    done

    w_host=$w_target
    ((w_alias > w_host)) && w_host=$w_alias

    if (( show_lines )); then
        printf '\e[2m%-*s  %-*s  %-*s  %-*s  %-*s  %s\e[0m\n' \
            "$w_nr" 'NR' \
            "$w_line" 'LINE' \
            "$w_host" 'TARGET' \
            "$w_host" 'ALIAS' \
            "$w_user" 'USER' \
            'KEYS'
    else
        printf '\e[2m%-*s  %-*s  %-*s  %-*s  %s\e[0m\n' \
            "$w_nr" 'NR' \
            "$w_host" 'TARGET' \
            "$w_host" 'ALIAS' \
            "$w_user" 'USER' \
            'KEYS'
    fi

    if (( ! found )); then
        if [[ -n $filter ]]; then
            printf 'No readable entries found for "%s".\n' "$filter"
        else
            printf 'No entries found.\n'
        fi
        return 0
    fi

    for gid in "${selected_ids[@]}"; do
        nr=$((gid + 1))

        if (( show_lines )); then
            printf '%-*s  %-*s  \e[36m%-*s  %-*s\e[0m  ' \
                "$w_nr" "$nr" \
                "$w_line" "${__kh_group_lines[$gid]}" \
                "$w_host" "${__kh_group_target[$gid]}" \
                "$w_host" "${__kh_group_alias[$gid]}"
        else
            printf '%-*s  \e[36m%-*s  %-*s\e[0m  ' \
                "$w_nr" "$nr" \
                "$w_host" "${__kh_group_target[$gid]}" \
                "$w_host" "${__kh_group_alias[$gid]}"
        fi

        if [[ ${__kh_group_user[$gid]} != '-' && ${__kh_group_user_explicit[$gid]:-0} != 1 ]]; then
            printf '\e[35m%-*s\e[0m' "$w_user" "${__kh_group_user[$gid]}"
        else
            printf '%-*s' "$w_user" "${__kh_group_user[$gid]}"
        fi

        printf '  \e[33m%s\e[0m\n' "${__kh_group_keys[$gid]}"
    done

    return 0
}
