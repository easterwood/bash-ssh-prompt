#!/usr/bin/env bash

# prompt-core.sh provides the command timer (__cmd_last_exit, __cmd_duration,
# __cmd_elapsed_us) and the shared text helpers this prompt reads. bashrc.sh
# and prompt.sh both source it first; make the requirement explicit rather
# than failing per prompt with "command not found".
declare -F __prompt_command_is_array >/dev/null || {
    printf '%s: bashrc.d/prompt-core.sh has to be sourced first.\n' \
        "${BASH_SOURCE[0]##*/}" >&2
    return 1
}

# Repeat the command that produced the current prompt, like the gruvbox and the
# remote prompt do. Text and truncation come from prompt-core.sh, so all three
# prompts show the same thing.
: "${PROMPT_LOCAL_SHOW_COMMAND:=1}"
: "${PROMPT_LOCAL_COMMAND_MAX_LEN:=60}"

# Same order as the gruvbox prompt: duration, last command, exit code.
prompt_callback() {
    local rc=${__cmd_last_exit:-0}
    local duration=${__cmd_duration:-}
    local elapsed_us=${__cmd_elapsed_us:-0}

    if (( rc != 0 )); then
        [[ -z $duration ]] || printf '  %s' "$duration"
    elif (( elapsed_us >= 100000 )); then
        printf '  %s%s%s' "$Green" "$duration" "$ResetColor"
    fi

    if (( PROMPT_LOCAL_SHOW_COMMAND )) &&
        __prompt_last_command "$PROMPT_LOCAL_COMMAND_MAX_LEN"; then
        printf '  %s%s%s' "${BoldBlue-}" "$REPLY" "${ResetColor-}"
    fi

    if (( rc != 0 )); then
        printf '  %s✗ %d%s' "$Red" "$rc" "$ResetColor"
    fi
}

# The timer has to run before bash-git-prompt.
if __prompt_command_is_array; then
    PROMPT_COMMAND=(__cmd_timer_stop "${PROMPT_COMMAND[@]}")
else
    PROMPT_COMMAND="__cmd_timer_stop${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

# ---------------------------------------------------------------------------
# bash-git-prompt
#
# These variables have to be set BEFORE gitprompt.sh is sourced, otherwise the
# defaults win. Each one removes Git calls or forks from every single prompt,
# and under MSYS2 a fork costs 15-25 ms.
# ---------------------------------------------------------------------------

GIT_PROMPT_ONLY_IN_REPO=0
GIT_PROMPT_THEME=Custom
GIT_PROMPT_SHOW_UPSTREAM=1
GIT_PROMPT_THEME_FILE="$BASH_CONFIG_ROOT/.git-prompt-colors.sh"

# The biggest win. Without it bash-git-prompt checks the remote behind the
# prompt, which means the prompt waits for the network whenever the remote is
# slow or unreachable (VPN down, proxy, laptop offline). The up/down arrows
# then only reflect the last explicit fetch, which is the usual trade.
GIT_PROMPT_FETCH_REMOTE_STATUS=1

# "git status --untracked-files=no" does not walk untracked directories.
# node_modules, target/ and build/ alone can cost hundreds of milliseconds.
# The price is that the "…n" untracked marker disappears from the prompt; set
# this to "normal" if you would rather keep it.
GIT_PROMPT_SHOW_UNTRACKED_FILES=normal

# No extra Git call per submodule.
GIT_PROMPT_IGNORE_SUBMODULES=0

# No node/python/conda environment detection per prompt.
GIT_PROMPT_WITH_VIRTUAL_ENV=0

# No counting of changed files.
GIT_PROMPT_SHOW_CHANGED_FILES_COUNT=1

if [[ -r "$HOME/.bash-git-prompt/gitprompt.sh" ]]; then
    source "$HOME/.bash-git-prompt/gitprompt.sh"
fi

# Arm the DEBUG hook as the last prompt action.
if __prompt_command_is_array; then
    PROMPT_COMMAND+=(__cmd_timer_arm)
else
    PROMPT_COMMAND="${PROMPT_COMMAND%;};__cmd_timer_arm"
fi
