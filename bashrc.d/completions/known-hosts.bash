#!/usr/bin/env bash

_ssh_known_hosts_completion() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local cur word i have_filter=0 have_fingerprints=0
    local -a options=(--lines --refresh --fingerprints --help)
    local -a words=()

    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}

    for ((i=1; i<COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            --fingerprints)
                have_fingerprints=1
                ;;
            --lines|--refresh|--help|-h|--)
                ;;
            -*)
                ;;
            *)
                have_filter=1
                ;;
        esac
    done

    (( have_fingerprints == 0 )) || return 0

    # Options may appear before or after the filter.
    if [[ $cur == -* ]]; then
        for word in "${options[@]}"; do
            [[ $word == "$cur"* ]] || continue
            COMPREPLY+=("$word")
        done
        return 0
    fi

    # Only a single free-form FILTER is allowed.
    (( have_filter == 0 )) || return 0

    __ssh_completion_cache_ensure "$known_hosts_file" "$config" || return 0
    words+=("${__ssh_completion_filter_hosts[@]}")

    for word in "${words[@]}"; do
        [[ $word == "$cur"* ]] || continue
        COMPREPLY+=("$word")
    done

    return 0
}
