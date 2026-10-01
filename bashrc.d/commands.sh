#!/usr/bin/env bash

# Overview of the commands this Bash configuration provides.
#
# The table in bash_config_commands is hand-maintained on purpose: what a
# command does cannot be derived from the code. So the table does not go stale
# unnoticed, "--check" verifies that every listed command really is defined in
# the running shell.

declare -F __opt_filter_set >/dev/null || {
    printf 'commands.sh: lib/options.sh has to be sourced first.\n' >&2
    return 1
}

# Kind of a command in the running shell. Returns 1 if it is missing.
__bash_commands_kind() {
    local name=$1 kind

    if alias "$name" >/dev/null 2>&1; then
        printf 'Alias\n'
        return 0
    fi

    kind=$(type -t "$name" 2>/dev/null || true)
    case $kind in
        function) printf 'Function\n' ;;
        builtin)  printf 'Builtin\n' ;;
        file)     printf 'Program\n' ;;
        *)        return 1 ;;
    esac
}

__bash_commands_usage() {
    printf 'Usage: bash-commands [--details] [FILTER]\n'
    printf '       bash-commands --check\n'
    printf '\n'
    printf '  --details, -d  Also show options, synonyms and source file\n'
    printf '  --check        Check that every command is defined\n'
    printf '  --help, -h     Show this help\n'
    printf '\n'
    printf 'FILTER is a substring and ignores case.\n'
    printf 'Name, synonyms and description are searched.\n'
}

bash_config_commands() {
    local sep=$'\x1f'
    local filter='' details=0 check=0
    local arg group row name synonyms source description options kind
    local current_group='' filter_lc width=0 found=0 missing=0
    local -a selected=()

    # GROUP | COMMAND | SYNONYMS | SOURCE | DESCRIPTION | OPTIONS
    local -a rows=(
"Prompt and display${sep}ll${sep}-${sep}bashrc.d/listing.sh${sep}Directory listing with aligned columns and a colour-coded owner${sep}all options of ls"
"SSH connection${sep}sshp${sep}-${sep}ssh-prompt.sh${sep}Copy the prompt files to the destination and log in${sep}[--force] [SSH-OPTIONS ...] DESTINATION"
"SSH connection${sep}ssh-nr${sep}-${sep}bashrc.d/lib/ssh-by-number.sh${sep}Log in by the target number from known-hosts${sep}NR [SSH-OPTIONS ...] | --list | --help"
"SSH overview${sep}known-hosts${sep}ssh-known-hosts${sep}bashrc.d/lib/known-hosts.sh${sep}Known SSH targets with alias, user and target number; --clean removes stale entries${sep}[--lines] [--refresh] [FILTER] | --fingerprints | --clean [--apply]"
"SSH overview${sep}ssh-resolve-ips${sep}-${sep}bashrc.d/lib/ssh-resolve-ips.sh${sep}Reverse-DNS for IPs from the SSH config and known_hosts${sep}[FILTER] | --refresh | --help"
"SSH overview${sep}ssh-resolve-hosts${sep}-${sep}bashrc.d/lib/ssh-resolve-hosts.sh${sep}Forward-DNS for hostnames from the SSH config and known_hosts${sep}[FILTER] | --refresh | --help"
"Help${sep}bash-commands${sep}bashrc-help${sep}bashrc.d/commands.sh${sep}Show this overview${sep}[--details] [FILTER] | --check | --help"
    )

    while (( $# )); do
        arg=$1
        shift

        case $arg in
            --details|-d)
                details=1
                ;;
            --check)
                check=1
                ;;
            --help|-h)
                __bash_commands_usage
                return 0
                ;;
            --)
                __opt_filter_separator 'bash-commands' "$@" || return 2
                # __opt_filter_consumed is set by that helper in lib/options.sh,
                # which the source-time guard above requires. ShellCheck sees
                # one file at a time.
                # shellcheck disable=SC2154
                ((! __opt_filter_consumed)) || shift
                ;;
            -*)
                printf 'bash-commands: unknown option: %s\n' "$arg" >&2
                __bash_commands_usage >&2
                return 2
                ;;
            *)
                __opt_filter_set 'bash-commands' "$arg" || return 2
                ;;
        esac
    done

    if (( check )); then
        if (( details )) || [[ -n $filter ]]; then
            printf 'bash-commands: --check cannot be combined with FILTER or --details.\n' >&2
            return 2
        fi

        # Synonyms are indented and can be longer than the command itself.
        for row in "${rows[@]}"; do
            IFS=$sep read -r group name synonyms source description options <<< "$row"
            ((${#name} > width)) && width=${#name}
            if [[ $synonyms != '-' ]] && (( ${#synonyms} + 2 > width )); then
                width=$(( ${#synonyms} + 2 ))
            fi
        done
        ((width >= 18)) || width=18

        printf '\e[2m%-*s  %-10s  %s\e[0m\n' "$width" 'COMMAND' 'KIND' 'SOURCE'
        for row in "${rows[@]}"; do
            IFS=$sep read -r group name synonyms source description options <<< "$row"

            if kind=$(__bash_commands_kind "$name"); then
                printf '\e[36m%-*s\e[0m  %-10s  \e[2m%s\e[0m\n' \
                    "$width" "$name" "$kind" "$source"
            else
                printf '\e[36m%-*s\e[0m  \e[31m%-10s\e[0m  \e[2m%s\e[0m\n' \
                    "$width" "$name" 'missing' "$source"
                ((missing+=1))
            fi

            # Synonyms have to exist as well, otherwise the table is stale.
            if [[ $synonyms != '-' ]]; then
                if kind=$(__bash_commands_kind "$synonyms"); then
                    printf '\e[36m%-*s\e[0m  %-10s  \e[2m%s\e[0m\n' \
                        "$width" "  $synonyms" "$kind" 'Synonym'
                else
                    printf '\e[36m%-*s\e[0m  \e[31m%-10s\e[0m  \e[2m%s\e[0m\n' \
                        "$width" "  $synonyms" 'missing' 'Synonym'
                    ((missing+=1))
                fi
            fi
        done

        printf '\n'
        if (( missing )); then
            printf '%d entry/entries missing. Is the table in bashrc.d/commands.sh up to date?\n' \
                "$missing"
            return 1
        fi
        printf 'Every listed command is defined.\n'
        return 0
    fi

    filter_lc=${filter,,}

    for row in "${rows[@]}"; do
        IFS=$sep read -r group name synonyms source description options <<< "$row"

        if [[ -n $filter ]]; then
            local haystack="$name $synonyms $description"
            [[ ${haystack,,} == *"$filter_lc"* ]] || continue
        fi

        selected+=("$row")
        found=1
        ((${#name} > width)) && width=${#name}
    done

    ((width >= 18)) || width=18

    if (( ! found )); then
        printf 'No commands found for "%s".\n' "$filter"
        return 0
    fi

    for row in "${selected[@]}"; do
        IFS=$sep read -r group name synonyms source description options <<< "$row"

        if [[ $group != "$current_group" ]]; then
            [[ -z $current_group ]] || printf '\n'
            printf '\e[1m%s\e[0m\n' "$group"
            current_group=$group
        fi

        printf '  \e[36m%-*s\e[0m  %s' "$width" "$name" "$description"
        __bash_commands_kind "$name" >/dev/null ||
            printf ' \e[31m(not defined)\e[0m'
        printf '\n'

        (( details )) || continue

        printf '  %-*s  \e[2mUsage:\e[0m    %s\n' "$width" '' "$options"
        [[ $synonyms == '-' ]] ||
            printf '  %-*s  \e[2mSynonym:\e[0m  %s\n' "$width" '' "$synonyms"
        printf '  %-*s  \e[2mSource:\e[0m   %s\n' "$width" '' "$source"
    done

    if (( ! details )); then
        printf '\n\e[2m%s\e[0m\n' \
            'More detail: bash-commands --details   Docs: docs/ in the Git project'
    fi

    return 0
}
