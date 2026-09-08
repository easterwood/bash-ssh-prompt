#!/usr/bin/env bash

# Options whose next word is an argument. We only need this to determine
# whether the current word is the SSH destination.
__ssh_completion_option_takes_arg() {
    case $1 in
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-P|-p|-Q|-R|-S|-W|-w)
            return 0
            ;;
    esac
    return 1
}

__ssh_completion_is_destination_position() {
    local i word expect_arg=0 options_done=0

    for ((i=1; i<COMP_CWORD; i++)); do
        word=${COMP_WORDS[i]}

        if (( expect_arg )); then
            expect_arg=0
            continue
        fi

        if (( options_done )); then
            # A destination was already supplied before the current word.
            return 1
        fi

        if [[ $word == -- ]]; then
            options_done=1
            continue
        fi

        if [[ $word == -* && $word != - ]]; then
            # Argument attached to the option, for example -p2222 or -luser.
            if __ssh_completion_option_takes_arg "${word:0:2}"; then
                [[ ${#word} -gt 2 ]] || expect_arg=1
            fi
            continue
        fi

        # First non-option word is the destination.
        return 1
    done

    (( ! expect_arg ))
}

__ssh_completion_file_argument() {
    local prev=${COMP_WORDS[COMP_CWORD-1]-}
    local cur=${COMP_WORDS[COMP_CWORD]}

    case $prev in
        -F|-i|-E|-I|-S)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
    esac

    return 1
}

_ssh_tools_ssh_completion() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local cur host prefix host_part

    COMPREPLY=()

    # Keep useful filename completion for the common file-valued options.
    __ssh_completion_file_argument && return 0

    __ssh_completion_is_destination_position || return 0
    __ssh_completion_cache_ensure "$known_hosts_file" "$config" || return 0

    cur=${COMP_WORDS[COMP_CWORD]}
    prefix=''
    host_part=$cur

    # ssh user@ho<TAB>
    if [[ $cur == *@* ]]; then
        prefix=${cur%@*}@
        host_part=${cur##*@}
    fi

    for host in "${__ssh_completion_connect_hosts[@]}"; do
        [[ $host == "$host_part"* ]] || continue
        COMPREPLY+=("$prefix$host")
    done

    return 0
}
