#!/usr/bin/env bash

_ssh_known_hosts_completion() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local cur word
    local -a words=(--refresh --fingerprints)

    COMPREPLY=()
    (( COMP_CWORD == 1 )) || return 0

    __ssh_completion_cache_ensure "$known_hosts_file" "$config" || return 0
    words+=("${__ssh_completion_filter_hosts[@]}")

    cur=${COMP_WORDS[COMP_CWORD]}
    for word in "${words[@]}"; do
        [[ $word == "$cur"* ]] || continue
        COMPREPLY+=("$word")
    done

    return 0
}
