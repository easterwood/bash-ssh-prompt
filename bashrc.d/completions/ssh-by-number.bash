#!/usr/bin/env bash

_ssh_by_number_completion() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local cur nr

    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}

    # The target number is always the first argument.
    (( COMP_CWORD == 1 )) || return 0

    if [[ $cur == -* ]]; then
        [[ --help == "$cur"* ]] && COMPREPLY+=(--help)
        [[ --list == "$cur"* ]] && COMPREPLY+=(--list)
        return 0
    fi

    [[ -r $known_hosts_file ]] || return 0
    __kh_groups_build "$known_hosts_file" "$config" || return 0

    for ((nr=1; nr<=__kh_group_count; nr++)); do
        [[ $nr == "$cur"* ]] || continue
        COMPREPLY+=("$nr")
    done
}
