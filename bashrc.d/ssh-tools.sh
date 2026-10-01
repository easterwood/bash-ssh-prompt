#!/usr/bin/env bash

# shellcheck source-path=SCRIPTDIR
# Entry point for the SSH helpers. Source this file from ~/.bashrc.

__ssh_tools_dir=${BASH_SOURCE[0]%/*}
[[ $__ssh_tools_dir != "${BASH_SOURCE[0]}" ]] || __ssh_tools_dir=.
__ssh_tools_dir=$(cd -- "$__ssh_tools_dir" && pwd) || return 1

# Shared option-parsing conventions; no dependencies of its own.
# shellcheck source=lib/options.sh
source "$__ssh_tools_dir/lib/options.sh"
# shellcheck source=lib/ssh-config.sh
source "$__ssh_tools_dir/lib/ssh-config.sh"
# shellcheck source=lib/known-hosts.sh
source "$__ssh_tools_dir/lib/known-hosts.sh"
# The --clean pass builds on the cache above and is a separate file.
# shellcheck source=lib/known-hosts-clean.sh
source "$__ssh_tools_dir/lib/known-hosts-clean.sh"
# shellcheck source=lib/ssh-by-number.sh
source "$__ssh_tools_dir/lib/ssh-by-number.sh"
# Both resolvers are thin wrappers around lib/ssh-resolve.sh, which therefore
# has to be loaded before them.
# shellcheck source=lib/ssh-resolve.sh
source "$__ssh_tools_dir/lib/ssh-resolve.sh"
# shellcheck source=lib/ssh-resolve-ips.sh
source "$__ssh_tools_dir/lib/ssh-resolve-ips.sh"
# shellcheck source=lib/ssh-resolve-hosts.sh
source "$__ssh_tools_dir/lib/ssh-resolve-hosts.sh"
# shellcheck source=completions/ssh-hosts.bash
source "$__ssh_tools_dir/completions/ssh-hosts.bash"
# shellcheck source=completions/known-hosts.bash
source "$__ssh_tools_dir/completions/known-hosts.bash"
# shellcheck source=completions/ssh-by-number.bash
source "$__ssh_tools_dir/completions/ssh-by-number.bash"
# shellcheck source=completions/ssh-resolve.bash
source "$__ssh_tools_dir/completions/ssh-resolve.bash"
# shellcheck source=completions/ssh.bash
source "$__ssh_tools_dir/completions/ssh.bash"
# shellcheck source=commands.sh
source "$__ssh_tools_dir/commands.sh"
# shellcheck source=completions/commands.bash
source "$__ssh_tools_dir/completions/commands.bash"

unalias known-hosts ssh-known-hosts ssh-resolve-ips ssh-resolve-hosts ssh-nr bash-commands bashrc-help 2>/dev/null || true
alias known-hosts='ssh_known_hosts'
alias ssh-known-hosts='ssh_known_hosts'
alias ssh-resolve-ips='ssh_resolve_ips'
alias ssh-resolve-hosts='ssh_resolve_hosts'
alias ssh-nr='ssh_by_number'
alias bash-commands='bash_config_commands'
alias bashrc-help='bash_config_commands'

complete -F _ssh_known_hosts_completion known-hosts
complete -F _ssh_known_hosts_completion ssh-known-hosts
complete -F _ssh_known_hosts_completion ssh_known_hosts

complete -F _ssh_resolve_completion ssh-resolve-ips
complete -F _ssh_resolve_completion ssh_resolve_ips
complete -F _ssh_resolve_completion ssh-resolve-hosts
complete -F _ssh_resolve_completion ssh_resolve_hosts

complete -F _ssh_by_number_completion ssh-nr
complete -F _ssh_by_number_completion ssh_by_number

complete -F _bash_commands_completion bash-commands
complete -F _bash_commands_completion bashrc-help
complete -F _bash_commands_completion bash_config_commands

# Host completion for the first destination argument. "ssh" is plain OpenSSH
# again and no longer wrapped, but the host completion is just as useful there,
# so both names keep it.
# Remove an older completion spec first so this registration is unambiguous.
complete -r ssh sshp 2>/dev/null || true
complete -F _ssh_tools_ssh_completion ssh
complete -F _ssh_tools_ssh_completion sshp

unset __ssh_tools_dir
