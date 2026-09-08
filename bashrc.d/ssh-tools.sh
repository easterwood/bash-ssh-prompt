#!/usr/bin/env bash

# Entry point for the SSH helpers. Source this file from ~/.bashrc.

__ssh_tools_dir=${BASH_SOURCE[0]%/*}
[[ $__ssh_tools_dir != "${BASH_SOURCE[0]}" ]] || __ssh_tools_dir=.
__ssh_tools_dir=$(cd -- "$__ssh_tools_dir" && pwd) || return 1

# shellcheck source=lib/ssh-config.sh
source "$__ssh_tools_dir/lib/ssh-config.sh"
# shellcheck source=lib/known-hosts.sh
source "$__ssh_tools_dir/lib/known-hosts.sh"
# shellcheck source=lib/known-hosts-clean.sh
source "$__ssh_tools_dir/lib/known-hosts-clean.sh"
# shellcheck source=completions/ssh-hosts.bash
source "$__ssh_tools_dir/completions/ssh-hosts.bash"
# shellcheck source=completions/known-hosts.bash
source "$__ssh_tools_dir/completions/known-hosts.bash"
# shellcheck source=completions/known-hosts-clean.bash
source "$__ssh_tools_dir/completions/known-hosts-clean.bash"
# shellcheck source=completions/ssh.bash
source "$__ssh_tools_dir/completions/ssh.bash"

unalias known-hosts ssh-known-hosts known-hosts-clean ssh-known-hosts-clean 2>/dev/null || true
alias known-hosts='ssh_known_hosts'
alias ssh-known-hosts='ssh_known_hosts'
alias known-hosts-clean='ssh_known_hosts_clean'
alias ssh-known-hosts-clean='ssh_known_hosts_clean'

complete -F _ssh_known_hosts_completion known-hosts
complete -F _ssh_known_hosts_completion ssh-known-hosts
complete -F _ssh_known_hosts_completion ssh_known_hosts

complete -F _ssh_known_hosts_clean_completion known-hosts-clean
complete -F _ssh_known_hosts_clean_completion ssh-known-hosts-clean
complete -F _ssh_known_hosts_clean_completion ssh_known_hosts_clean

# sshp is treated like ssh: the first destination argument gets host completion.
# Remove an older completion spec first so this registration is unambiguous.
complete -r ssh sshp 2>/dev/null || true
complete -F _ssh_tools_ssh_completion ssh
complete -F _ssh_tools_ssh_completion sshp

unset __ssh_tools_dir
