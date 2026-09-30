#!/usr/bin/env bash

# The __kh_* globals read here are defined in lib/ssh-config.sh and filled by
# its scanner and parser; bashrc.d/ssh-tools.sh guarantees the load order and
# every file checks it at source time. ShellCheck sees one file at a time.
# shellcheck disable=SC2154

# known-hosts: the shell-side cache over known_hosts, the grouping model that
# gives every target its stable NR, and the display.
#
# The --clean pass lives in lib/known-hosts-clean.sh and is loaded after this
# file; ssh_known_hosts only dispatches to it.
#
# Requires lib/ssh-config.sh.

declare -F __kh_parse_known_line >/dev/null || {
    printf 'known-hosts.sh: lib/ssh-config.sh has to be sourced first.\n' >&2
    return 1
}

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
        __kh_ssh_config_dump "$config" "$alias" || {
            printf 'known-hosts: could not evaluate the SSH configuration for alias %q.\n' "$alias" >&2
            return 1
        }
        resolved=$REPLY

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

        __kh_lookup_key "$host" "$keyalias" "$port"
        lookup=$REPLY

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
    local kh_line kh_line_number=0 raw_hosts raw_host effective_user
    while IFS= read -r kh_line || [[ -n $kh_line ]]; do
        ((kh_line_number+=1))
        __kh_parse_known_line "$kh_line" || continue

        raw_hosts=$__kh_line_hosts
        [[ -z ${__kh_rows[$kh_line_number]-} ]] || continue
        (( ! __kh_line_hashed )) || continue
        [[ $raw_hosts != *','* &&
           $raw_hosts != *'*'* &&
           $raw_hosts != *'?'* &&
           $raw_hosts != *'!'* ]] || continue
        [[ -z ${__kh_target_users["$raw_hosts"]+x} ]] || continue

        __kh_split_host_port "$raw_hosts"
        raw_host=$__kh_host

        __kh_ssh_config_dump "$config" "$raw_host" 1 || true
        resolved=$REPLY

        effective_user=''
        __kh_ssh_config_field "$resolved" user && effective_user=$REPLY

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

# Records one known_hosts line against a group, creating the group on first
# sight. Both branches of __kh_groups_build used to carry this verbatim.
# The caller owns group_id, line_seen and key_seen; they are visible here
# through Bash's dynamic scoping.
#
# __kh_groups_record GROUP_KEY ALIAS TARGET USER USER_EXPLICIT LINE KEY_TYPE
__kh_groups_record() {
    local group_key=$1 alias=$2 target=$3 user=$4 user_explicit=$5
    local line_number=$6 key_type=$7
    local gid seen_token

    if [[ -z ${group_id["$group_key"]+x} ]]; then
        gid=$__kh_group_count
        ((__kh_group_count+=1))
        group_id["$group_key"]=$gid
        __kh_group_alias[gid]=$alias
        __kh_group_target[gid]=$target
        __kh_group_user[gid]=$user
        __kh_group_user_explicit[gid]=${user_explicit:-0}
        __kh_group_lines[gid]=''
        __kh_group_keys[gid]=''
    else
        gid=${group_id["$group_key"]}
    fi

    seen_token="$gid$sep$line_number"
    if [[ -z ${line_seen["$seen_token"]+x} ]]; then
        line_seen["$seen_token"]=1
        if [[ -n ${__kh_group_lines[gid]} ]]; then
            __kh_group_lines[gid]+=",$line_number"
        else
            __kh_group_lines[gid]=$line_number
        fi
    fi

    seen_token="$gid$sep$key_type"
    if [[ -z ${key_seen["$seen_token"]+x} ]]; then
        key_seen["$seen_token"]=1
        if [[ -n ${__kh_group_keys[gid]} ]]; then
            __kh_group_keys[gid]+=", $key_type"
        else
            __kh_group_keys[gid]=$key_type
        fi
    fi
}

# Builds exactly the same groups known-hosts displays. The group order also
# defines the stable target number for the current state of the file.
__kh_groups_build() {
    local known_hosts_file=$1 config=$2
    local line line_number=0
    local marker hosts key_type display_hosts target
    local rows alias user lookup user_explicit
    local group_key
    local sep=$'\x1f'
    local -A group_id=() key_seen=() line_seen=()

    __kh_groups_reset
    __kh_cache_ensure "$known_hosts_file" "$config" || return

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number+=1))
        __kh_parse_known_line "$line" || continue

        marker=$__kh_line_marker
        hosts=$__kh_line_hosts
        key_type=$__kh_line_keytype

        [[ -n $key_type && -n $__kh_line_key ]] || continue

        if (( __kh_line_hashed )); then
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

                __kh_groups_record \
                    "A$sep$alias$sep$target$sep$user" \
                    "$alias" "$target" "$user" "$user_explicit" \
                    "$line_number" "$key_type"
            done <<< "$rows"
        else
            __kh_groups_record \
                "U$sep$marker$sep$hosts" \
                '-' "$display_hosts" \
                "${__kh_target_users["$hosts"]:--}" \
                "${__kh_target_user_explicit["$hosts"]:-0}" \
                "$line_number" "$key_type"
        fi
    done < "$known_hosts_file"
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
    local show_lines=0 refresh=0 fingerprints=0 clean=0 apply=0 clean_status=0
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
        clean_status=$?

        # __kh_clean_run works in a subshell, so an invalidation inside it
        # would not reach this shell. Dropping the caches after a successful
        # --apply is cheap and always correct: they are rebuilt on demand.
        if (( apply && clean_status == 0 )); then
            declare -F __kh_cache_invalidate >/dev/null && __kh_cache_invalidate
            declare -F __ssh_completion_cache_invalidate >/dev/null && __ssh_completion_cache_invalidate
        fi
        return "$clean_status"
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
