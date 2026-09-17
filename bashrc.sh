#!/usr/bin/env bash

[[ $- == *i* ]] || return 0

BASH_CONFIG_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export BASH_CONFIG_ROOT

source "$BASH_CONFIG_ROOT/bashrc.d/environment.sh"
# prompt-core.sh only defines functions and has to come first: history.sh and
# prompt-local.sh use __prompt_command_is_array from it.
source "$BASH_CONFIG_ROOT/bashrc.d/prompt-core.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/history.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/listing.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/ssh-tools.sh"
source "$BASH_CONFIG_ROOT/ssh-prompt.sh"

# Untracked, machine-specific overrides are optional. They are loaded before
# the local prompt backend so local.sh can select and configure that backend.
[[ ! -r "$BASH_CONFIG_ROOT/local.sh" ]] || source "$BASH_CONFIG_ROOT/local.sh"

# Local prompt backend. Set BASH_PROMPT_BACKEND in local.sh to one of:
#   starship | bash-git-prompt | gruvbox | auto
# "auto" preserves the previous behaviour: Starship when installed, otherwise
# the shell-only Gruvbox prompt. The long module names are accepted as aliases.
__prompt_backend=${BASH_PROMPT_BACKEND:-auto}
case $__prompt_backend in
    auto)
        if command -v starship >/dev/null 2>&1; then
            __prompt_backend=starship
        else
            __prompt_backend=gruvbox
        fi
        ;;
    prompt-local|git)
        __prompt_backend=bash-git-prompt
        ;;
    prompt-gruvbox|prompt-gruvbox.sh)
        __prompt_backend=gruvbox
        ;;
esac

case $__prompt_backend in
    starship)
        if command -v starship >/dev/null 2>&1; then
            export STARSHIP_CONFIG=${STARSHIP_CONFIG:-"$BASH_CONFIG_ROOT/starship.toml"}
            eval "$(starship init bash)"
        else
            printf 'bashrc: BASH_PROMPT_BACKEND=starship, but starship is not installed; using gruvbox.\n' >&2
            source "$BASH_CONFIG_ROOT/bashrc.d/prompt-gruvbox.sh"
        fi
        ;;
    bash-git-prompt)
        if [[ -r "$HOME/.bash-git-prompt/gitprompt.sh" ]]; then
            source "$BASH_CONFIG_ROOT/bashrc.d/prompt-local.sh"
        else
            printf 'bashrc: BASH_PROMPT_BACKEND=bash-git-prompt, but ~/.bash-git-prompt/gitprompt.sh is missing; using gruvbox.\n' >&2
            source "$BASH_CONFIG_ROOT/bashrc.d/prompt-gruvbox.sh"
        fi
        ;;
    gruvbox)
        source "$BASH_CONFIG_ROOT/bashrc.d/prompt-gruvbox.sh"
        ;;
    *)
        printf 'bashrc: unknown BASH_PROMPT_BACKEND=%q; expected starship, bash-git-prompt, gruvbox, or auto; using gruvbox.\n' \
            "$__prompt_backend" >&2
        source "$BASH_CONFIG_ROOT/bashrc.d/prompt-gruvbox.sh"
        ;;
esac
unset __prompt_backend
