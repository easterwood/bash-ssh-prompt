#!/usr/bin/env bash

prompt_callback() {
    local rc=${__cmd_last_exit:-0}
    local duration=${__cmd_duration:-}
    local elapsed_us=${__cmd_elapsed_us:-0}

    if (( rc != 0 )); then
        printf '  %s✗ %d%s' "$Red" "$rc" "$ResetColor"
        [[ -z $duration ]] || printf ' · %s' "$duration"
    elif (( elapsed_us >= 100000 )); then
        printf '  %s%s%s' "$Green" "$duration" "$ResetColor"
    fi
}

# Timer muss vor bash-git-prompt ausgeführt werden.
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
    PROMPT_COMMAND=(__cmd_timer_stop "${PROMPT_COMMAND[@]}")
else
    PROMPT_COMMAND="__cmd_timer_stop${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

GIT_PROMPT_ONLY_IN_REPO=0
GIT_PROMPT_THEME=Custom
GIT_PROMPT_SHOW_UPSTREAM=1
GIT_PROMPT_THEME_FILE="$BASH_CONFIG_ROOT/.git-prompt-colors.sh"

if [[ -r "$HOME/.bash-git-prompt/gitprompt.sh" ]]; then
    source "$HOME/.bash-git-prompt/gitprompt.sh"
fi

# DEBUG-Hook als letzte Prompt-Aktion aktivieren.
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
    PROMPT_COMMAND+=(__cmd_timer_arm)
else
    PROMPT_COMMAND="${PROMPT_COMMAND%;};__cmd_timer_arm"
fi
