#!/usr/bin/env bash

# Completion for ssh-resolve-ips and ssh-resolve-hosts. Both take the same
# single argument — a filter, --refresh or --help — so one function is
# registered for both commands instead of two identical copies.
#
# COMPREPLY is filled in a loop rather than from $(compgen ...): an unquoted
# command substitution would word-split a filter containing spaces.
_ssh_resolve_completion() {
    local cur=${COMP_WORDS[COMP_CWORD]} word

    COMPREPLY=()
    (( COMP_CWORD == 1 )) || return 0

    for word in --refresh --help; do
        [[ $word == "$cur"* ]] || continue
        COMPREPLY+=("$word")
    done
}
