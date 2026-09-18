#!/usr/bin/env bash

# Fork-free test for an array-valued PROMPT_COMMAND.
#
# The previous test was $(declare -p PROMPT_COMMAND), and a command
# substitution forks. Under MSYS2/Cygwin a fork costs 15-25 ms because Windows
# has no fork() and Cygwin emulates it with CreateProcess plus a memory image.
# The test ran four times across the startup files, so this alone saves about
# 60 ms per shell start.
#
# PROMPT_COMMAND can only be an array from Bash 5.1 on, so on older shells the
# answer is always "no" and the ${var@a} expansion is never reached.
__prompt_command_is_array() {
    ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))) &&
        [[ ${PROMPT_COMMAND@a} == *a* ]]
}

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

# Dynamic text ends up in PS1, which bash expands. A branch called '$(id)' or a
# repeated command carrying backticks would otherwise run. Escape the three
# characters that matter. Both prompt modules use this.
__prompt_quote() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\$/\\\$}
    s=${s//\`/\\\`}
    REPLY=$s
}

# The repetition of the last command, the way every prompt here shows it:
# control characters folded into spaces, truncated to $1 characters (default
# 60), PS1-safe in REPLY. Returns 1 when there is nothing to show.
__prompt_last_command() {
    local max=${1:-60} text=${__cmd_last_command-}

    REPLY=''
    [[ -n $text ]] || return 1

    text=${text//[$'\n\r\t']/ }
    (( ${#text} > max )) && text=${text:0:max-1}$'\u2026'
    __prompt_quote "$text"
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
        setLastCommandState|__cmd_timer_stop|__gb_build|__remote_prompt_build|__cmd_timer_arm)
            return
            ;;
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
                printf -v __cmd_duration '%d.%03ds' \
                    "$total_s" "$(((elapsed_us / 1000) % 1000))"
            elif (( total_s < 3600 )); then
                printf -v __cmd_duration '%dm%02ds' \
                    "$((total_s / 60))" "$((total_s % 60))"
            else
                printf -v __cmd_duration '%dh%02dm%02ds' \
                    "$((total_s / 3600))" "$(((total_s / 60) % 60))" \
                    "$((total_s % 60))"
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
