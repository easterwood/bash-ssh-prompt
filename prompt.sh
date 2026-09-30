#!/usr/bin/env bash

[[ $- == *i* ]] || return 0
: "${SSH_PROMPT_SHOW_COMMAND:=1}"

__remote_prompt_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$__remote_prompt_root/bashrc.d/listing.sh"
source "$__remote_prompt_root/bashrc.d/prompt-core.sh"

if [[ -n ${SSH_CONNECTION-} && -z ${SSHP_WELCOME_SHOWN-} ]]; then
    read -r _ _ __ssh_server_address _ <<< "$SSH_CONNECTION"
    __ssh_remote_host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf '?')
    printf '\e[1;36m╭─ REMOTE\e[0m  %s\n' "$__ssh_remote_host"
    printf '\e[1;36m╰─ USER  \e[0m  %s · IP %s\n' \
        "${USER:-$(id -un)}" "${__ssh_server_address:-?}"
    export SSHP_WELCOME_SHOWN=1
    unset __ssh_server_address __ssh_remote_host
fi

# ---------------------------------------------------------------------------
# Remote prompt: the same Gruvbox powerline prompt as locally, with the
# differences a remote host actually needs.
#
#   * No Git segment. Remote hosts carry no Git configuration, and the segment
#     is the only per-prompt fork - over SSH that is the one thing worth
#     saving.
#   * The host name sits next to the user, because on a remote host that is
#     the information the local prompt does not have to carry.
#   * The last command is repeated in the second powerline line, so scrollback
#     read after the fact still says which command produced which exit code.
#
# The welcome banner above stays as it is.
# ---------------------------------------------------------------------------

PROMPT_GRUVBOX_GIT=0
: "${PROMPT_GRUVBOX_SHOW_HOST:=1}"
: "${PROMPT_GRUVBOX_SHOW_COMMAND:=$SSH_PROMPT_SHOW_COMMAND}"

# The pre-4.2 fallback prompt.
#
# prompt-gruvbox.sh needs associative arrays and $'\Uxxxxxxxx', both Bash 4.2,
# and would not even parse on an older shell. A stock macOS bash is 3.2, so on
# a Mac this is the prompt sshp actually gives you, not an exotic corner; an
# old AIX or Solaris lands here too.
#
# The function is defined unconditionally. Only the wiring below depends on the
# version, which is what makes the builder reachable from tests/remote-prompt.sh
# on a modern shell -- BASH_VERSINFO is readonly and cannot be faked.
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
        __prompt_quote "$__cmd_last_command"
        PS1="\[\e[2m\]last: ${REPLY}\[\e[0m\]\n"
    else
        PS1=''
    fi
    PS1+="${first_line}${status}\n\t ${symbol_color}${symbol}\[\e[0m\] "
}

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))); then
    # The remote prompt deliberately ignores prompt hooks inherited from the
    # server. Gruvbox then composes its fixed sequence through prompt-core.sh.
    __prompt_command_replace
    source "$__remote_prompt_root/bashrc.d/prompt-gruvbox.sh"
else
    __prompt_command_replace __cmd_timer_stop __remote_prompt_build __cmd_timer_arm
    __remote_prompt_build
fi

unset __remote_prompt_root
