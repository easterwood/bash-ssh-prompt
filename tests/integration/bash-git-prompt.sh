#!/usr/bin/env bash

# Compatibility test against a real bash-git-prompt checkout. This is kept
# outside tests/*.sh because the normal suite is intentionally network-free;
# CI checks out the pinned upstream version and passes its directory here.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." || exit 1

TEST_NAME='bash-git-prompt-upstream'
# shellcheck source=tests/lib.sh
source tests/lib.sh

upstream_dir=${1-}
[[ -n $upstream_dir && -r $upstream_dir/gitprompt.sh ]] ||
    fail 'usage: tests/integration/bash-git-prompt.sh UPSTREAM_CHECKOUT'
upstream_dir=$(cd -- "$upstream_dir" && pwd -P) || fail 'resolve upstream checkout'

config_root=$PWD
test_sandbox
ln -s -- "$upstream_dir" "$HOME/.bash-git-prompt" || fail 'link upstream checkout'

BASH_CONFIG_ROOT=$config_root
PROMPT_COMMAND=${PROMPT_COMMAND-}
PS1=${PS1-}

# shellcheck source=bashrc.d/prompt-core.sh
source bashrc.d/prompt-core.sh
# shellcheck source=bashrc.d/prompt-local.sh
source bashrc.d/prompt-local.sh

assert_equal 'real gitprompt.sh installs setGitPrompt' function "$(type -t setGitPrompt)"
assert_equal 'remote fetches stay disabled after upstream init' 0 "$GIT_PROMPT_FETCH_REMOTE_STATUS"
assert_equal 'untracked-file scanning stays disabled after upstream init' no "$GIT_PROMPT_SHOW_UNTRACKED_FILES"
assert_equal 'submodule scanning stays disabled after upstream init' 1 "$GIT_PROMPT_IGNORE_SUBMODULES"
assert_equal 'changed-file counting stays disabled after upstream init' 0 "$GIT_PROMPT_SHOW_CHANGED_FILES_COUNT"

if __prompt_command_is_array; then
    old_ifs=$IFS
    IFS=';'
    joined=${PROMPT_COMMAND[*]-}
    IFS=$old_ifs
else
    joined=${PROMPT_COMMAND-}
fi
assert_contains 'timer stop remains before the upstream prompt hook' "$joined" '__cmd_timer_stop'
assert_contains 'upstream installs its prompt hook' "$joined" 'setGitPrompt'
assert_contains 'timer arm remains after upstream initialization' "$joined" '__cmd_timer_arm'

# Exercise one real render in an actual Git repository. No remote is configured,
# so this remains deterministic and performs no network access.
repo=$TEST_TMP/repo
mkdir -p "$repo" || fail 'create git repository'
git -C "$repo" init -q || fail 'git init'
printf 'tracked\n' > "$repo/tracked.txt"
git -C "$repo" add tracked.txt || fail 'git add'
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm initial ||
    fail 'git commit'
printf 'untracked\n' > "$repo/untracked.txt"
cd -- "$repo" || fail 'enter git repository'
setGitPrompt >/dev/null 2>&1 || :
assert 'real upstream render produces PS1' test -n "$PS1"

pass 'pinned upstream initializes and renders with the performance switches disabled'
