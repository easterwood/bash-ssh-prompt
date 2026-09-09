#!/usr/bin/env bash

_bash_commands_completion() {
    local cur word i have_filter=0 have_check=0
    local -a options=(--details --check --help)
    local -a names=(
        ll
        ssh
        sshp
        ssh-nr
        known-hosts
        ssh-known-hosts
        ssh-resolve-ips
        ssh-resolve-hosts
        known-hosts-clean
        ssh-known-hosts-clean
        bash-commands
        bashrc-help
    )

    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}

    for ((i=1; i<COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            --check)
                have_check=1
                ;;
            --details|-d|--help|-h|--)
                ;;
            -*)
                ;;
            *)
                have_filter=1
                ;;
        esac
    done

    # No further argument is meaningful after --check.
    (( have_check == 0 )) || return 0

    if [[ $cur == -* ]]; then
        for word in "${options[@]}"; do
            [[ $word == "$cur"* ]] || continue
            COMPREPLY+=("$word")
        done
        return 0
    fi

    # Only a single free-form FILTER is allowed.
    (( have_filter == 0 )) || return 0

    for word in "${names[@]}"; do
        [[ $word == "$cur"* ]] || continue
        COMPREPLY+=("$word")
    done

    return 0
}
