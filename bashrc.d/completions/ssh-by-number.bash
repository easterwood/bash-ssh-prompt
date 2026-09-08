#!/usr/bin/env bash

_ssh_by_number_completion() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local cur nr i first_nr_word=1

    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}

    # Vor der Zielnummer koennen die Quiet-Schalter stehen.
    for ((i=1; i<COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            --banner|--no-quiet|--quiet)
                ((first_nr_word+=1))
                ;;
            *)
                break
                ;;
        esac
    done

    (( COMP_CWORD == first_nr_word )) || return 0

    if [[ $cur == -* ]]; then
        [[ --help == "$cur"* ]] && COMPREPLY+=(--help)
        [[ --list == "$cur"* ]] && COMPREPLY+=(--list)
        [[ --banner == "$cur"* ]] && COMPREPLY+=(--banner)
        [[ --no-quiet == "$cur"* ]] && COMPREPLY+=(--no-quiet)
        return 0
    fi

    [[ -r $known_hosts_file ]] || return 0
    __kh_groups_build "$known_hosts_file" "$config" || return 0

    for ((nr=1; nr<=__kh_group_count; nr++)); do
        [[ $nr == "$cur"* ]] || continue
        COMPREPLY+=("$nr")
    done
}
