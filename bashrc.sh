#!/usr/bin/env bash

[[ $- == *i* ]] || return 0

BASH_CONFIG_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export BASH_CONFIG_ROOT

source "$BASH_CONFIG_ROOT/bashrc.d/environment.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/history.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/listing.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/ssh-tools.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/prompt-core.sh"
source "$BASH_CONFIG_ROOT/bashrc.d/prompt-local.sh"
source "$BASH_CONFIG_ROOT/ssh-prompt.sh"

# Nicht versionierte, rechnerbezogene Ausnahmen sind optional.
[[ ! -r "$BASH_CONFIG_ROOT/local.sh" ]] || source "$BASH_CONFIG_ROOT/local.sh"
