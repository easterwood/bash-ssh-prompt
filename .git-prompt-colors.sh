# Every GIT_PROMPT_* variable below is read by bash-git-prompt after it calls
# this function, and every colour name is defined by the theme it loads before
# calling it. Neither side is visible to ShellCheck.
# shellcheck disable=SC2034,SC2154
override_git_prompt_colors() {
    GIT_PROMPT_THEME_NAME="Custom"
    local host_prefix=""

    if [[ -n ${SSH_CONNECTION-} ]]; then
        host_prefix="${Cyan}\u@\h ${ResetColor}"
    fi

    GIT_PROMPT_START_USER="${host_prefix}${Yellow}${PathShort}${ResetColor}"
    GIT_PROMPT_START_ROOT="${host_prefix}${Red}${PathShort}${ResetColor}"
    GIT_PROMPT_LEADING_SPACE=0
    GIT_PROMPT_PREFIX=$'\n'
    GIT_PROMPT_SUFFIX=""
    GIT_PROMPT_SEPARATOR=" "
    GIT_PROMPT_COMMAND_OK=""
    GIT_PROMPT_COMMAND_FAIL=""
    GIT_PROMPT_END_USER=$'\n'"\t ${BoldGreen}❯${ResetColor} "
    GIT_PROMPT_END_ROOT=$'\n'"\t ${BoldRed}#${ResetColor} "
}

reload_git_prompt_colors "Custom"
