#!/usr/bin/env bash

_ssh_known_hosts_clean_completion() {
    local cur=${COMP_WORDS[COMP_CWORD]-}
    local word
    local -a words=(--apply --help)

    COMPREPLY=()
    (( COMP_CWORD == 1 )) || return 0

    for word in "${words[@]}"; do
        [[ $word == "$cur"* ]] || continue
        COMPREPLY+=("$word")
    done

    return 0
}
