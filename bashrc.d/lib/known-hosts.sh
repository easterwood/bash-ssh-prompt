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

# Exactly one row is printed per alias/target/user.
# Multiple known_hosts lines and key types are merged.
# NR is the unique target number used by ssh-nr.
ssh_known_hosts() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local filter=''
    local show_lines=0 refresh=0 fingerprints=0
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
            --help|-h)
                printf 'Usage: known-hosts [--lines] [--refresh] [FILTER]\n'
                printf '       known-hosts --fingerprints\n'
                printf '\n'
                printf '  --lines         Show the known_hosts line numbers\n'
                printf '  --refresh       Discard the cache and re-read the data\n'
                printf '  --fingerprints  Show the original ssh-keygen fingerprints\n'
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
                printf 'Usage: known-hosts [--lines] [--refresh] [FILTER]\n' >&2
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
