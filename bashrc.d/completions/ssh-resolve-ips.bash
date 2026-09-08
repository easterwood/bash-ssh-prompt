#!/usr/bin/env bash

_ssh_resolve_ips_completion() {
    local cur=${COMP_WORDS[COMP_CWORD]}

    if (( COMP_CWORD != 1 )); then
        COMPREPLY=()
        return 0
    fi

    COMPREPLY=( $(compgen -W '--refresh --help' -- "$cur") )
}
