#!/usr/bin/env bash

# Eigenstaendiger Prompt fuer SSH-Sitzungen ohne bash-git-prompt.
[[ $- == *i* ]] || return 0

: "${SSH_PROMPT_SHOW_COMMAND:=1}"

__cmd_timer_now_us() {
    local t sec usec
    if [[ -n ${EPOCHREALTIME-} ]]; then
        t=${EPOCHREALTIME/,/.}
        sec=${t%%.*}
        usec=${t#*.}000000
        usec=${usec:0:6}
        REPLY=$((10#$sec * 1000000 + 10#$usec))
    else
        REPLY=$(date +%s%6N)
    fi
}

__cmd_set_window_title() {
    local cmd=$1 dir
    cmd=${cmd//$'\e'/}
    cmd=${cmd//$'\a'/}
    cmd=${cmd//$'\r'/ }
    cmd=${cmd//$'\n'/ ; }
    cmd=${cmd//$'\t'/ }

    if [[ $PWD == "$HOME" ]]; then
        dir='~'
    elif [[ $PWD == / ]]; then
        dir='/'
    else
        dir=${PWD##*/}
    fi
    printf '\033]0;%s — %s\007' "$cmd" "$dir"
}

__cmd_timer_debug() {
    local current_command=$BASH_COMMAND history_line cmd
    case "$current_command" in
        __cmd_timer_stop|__ssh_prompt_build|__cmd_timer_arm) return ;;
    esac

    trap - DEBUG
    history_line=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1 2>/dev/null)
    if [[ $history_line =~ ^[[:space:]]*[0-9]+(\*|[[:space:]])[[:space:]]+(.*)$ ]]; then
        cmd=${BASH_REMATCH[2]}
    else
        cmd=$current_command
    fi
    cmd=${cmd#"${cmd%%[![:space:]]*}"}
    cmd=${cmd%"${cmd##*[![:space:]]}"}
    __cmd_last_command=$cmd
    __cmd_set_window_title "$cmd"
    __cmd_timer_now_us
    __cmd_timer_start_us=$REPLY
}

__cmd_timer_stop() {
    local rc=$? elapsed_us total_s
    trap - DEBUG
    __cmd_last_exit=$rc

    if [[ -n ${__cmd_timer_start_us-} ]]; then
        __cmd_timer_now_us
        elapsed_us=$((REPLY - __cmd_timer_start_us))
        __cmd_elapsed_us=$elapsed_us
        unset __cmd_timer_start_us

        if (( elapsed_us < 1000 )); then
            __cmd_duration='<1ms'
        elif (( elapsed_us < 1000000 )); then
            printf -v __cmd_duration '%dms' "$(((elapsed_us + 500) / 1000))"
        else
            total_s=$((elapsed_us / 1000000))
            if (( total_s < 60 )); then
                printf -v __cmd_duration '%d.%03ds' "$total_s" "$(((elapsed_us / 1000) % 1000))"
            elif (( total_s < 3600 )); then
                printf -v __cmd_duration '%dm%02ds' "$((total_s / 60))" "$((total_s % 60))"
            else
                printf -v __cmd_duration '%dh%02dm%02ds' "$((total_s / 3600))" "$(((total_s / 60) % 60))" "$((total_s % 60))"
            fi
        fi
    fi
    return "$rc"
}

__cmd_timer_arm() {
    if [[ -n ${__cmd_last_command-} ]]; then
        __cmd_set_window_title "$__cmd_last_command"
    fi
    trap '__cmd_timer_debug' DEBUG
}

__ssh_prompt_build() {
    local rc=${__cmd_last_exit:-0} status='' first_line symbol symbol_color

    if (( rc != 0 )); then
        status="  \[\e[31m\]✗ ${rc}\[\e[0m\]"
        [[ -z ${__cmd_duration-} ]] || status+=" · ${__cmd_duration}"
    elif (( ${__cmd_elapsed_us:-0} >= 100000 )); then
        status="  \[\e[32m\]${__cmd_duration}\[\e[0m\]"
    fi

    if [[ -n ${SSH_CONNECTION-} ]]; then
        first_line='\[\e[36m\]\u@\h \[\e[0m\]'
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
        PS1="\[\e[2m\]last: ${__cmd_last_command}\[\e[0m\]\n"
    else
        PS1=''
    fi
    PS1+="${first_line}${status}\n\t ${symbol_color}${symbol}\[\e[0m\] "
}

# Eigene Hooks genau einmal und in definierter Reihenfolge installieren.
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
    PROMPT_COMMAND=(__cmd_timer_stop __ssh_prompt_build __cmd_timer_arm)
else
    PROMPT_COMMAND='__cmd_timer_stop;__ssh_prompt_build;__cmd_timer_arm'
fi

__ssh_prompt_build
