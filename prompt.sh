#!/usr/bin/env bash

[[ $- == *i* ]] || return 0
: "${SSH_PROMPT_SHOW_COMMAND:=1}"

__remote_prompt_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$__remote_prompt_root/bashrc.d/listing.sh"
source "$__remote_prompt_root/bashrc.d/prompt-core.sh"
unset __remote_prompt_root

if [[ -n ${SSH_CONNECTION-} && -z ${SSHP_WELCOME_SHOWN-} ]]; then
    read -r _ _ __ssh_server_address _ <<< "$SSH_CONNECTION"
    __ssh_remote_host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf '?')
    printf '\e[1;36m╭─ REMOTE\e[0m  %s\n' "$__ssh_remote_host"
    printf '\e[1;36m╰─ USER  \e[0m  %s · IP %s\n' \
        "${USER:-$(id -un)}" "${__ssh_server_address:-?}"
    export SSHP_WELCOME_SHOWN=1
    unset __ssh_server_address __ssh_remote_host
fi

__remote_prompt_build() {
    local rc=${__cmd_last_exit:-0} status='' first_line symbol symbol_color

    if (( rc != 0 )); then
        status="  \[\e[31m\]✗ ${rc}\[\e[0m\]"
        [[ -z ${__cmd_duration-} ]] || status+=" · ${__cmd_duration}"
    elif (( ${__cmd_elapsed_us:-0} >= 100000 )); then
        status="  \[\e[32m\]${__cmd_duration}\[\e[0m\]"
    fi

    if [[ -n ${SSH_CONNECTION-} ]]; then
        first_line='\[\e[1;36m\][SSH \h]\[\e[0m\] '
    else
        first_line=''
    fi

    if (( EUID == 0 )); then
        first_line+='\[\e[31m\]\w\[\e[0m\]'
        symbol='#'
        symbol_color='\[\e[1;31m\]'
    else
        first_line+='\[\e[33m\]\w\[\e[0m\]'
        symbol='❯'
        symbol_color='\[\e[1;32m\]'
    fi

    if (( SSH_PROMPT_SHOW_COMMAND )) && [[ -n ${__cmd_last_command-} ]]; then
        PS1="\[\e[2m\]letzter: ${__cmd_last_command}\[\e[0m\]\n"
    else
        PS1=''
    fi
    PS1+="${first_line}${status}\n\t ${symbol_color}${symbol}\[\e[0m\] "
}

if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
    PROMPT_COMMAND=(__cmd_timer_stop __remote_prompt_build __cmd_timer_arm)
else
    PROMPT_COMMAND='__cmd_timer_stop;__remote_prompt_build;__cmd_timer_arm'
fi

__remote_prompt_build
