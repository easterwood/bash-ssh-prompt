#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for ssh-prompt.sh: the argument parser of sshp and the
# guards around it. No connection is made; the parser is exercised directly
# and the full function only through cases that fail before any ssh call.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='sshp'
# shellcheck source=tests/lib.sh
source tests/lib.sh

config_root=$PWD
test_sandbox

# shellcheck source=ssh-prompt.sh
source "$config_root/ssh-prompt.sh"

# --- weak-crypto warning policy -------------------------------------------

# Exercise the real capability probe once with a fake client. This proves the
# check is configuration-only (-G) and asks for the exact setting we gate.
export SSH_PROBE_LOG="$TEST_TMP/ssh-probe.log"
test_stub ssh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_PROBE_LOG"
[[ $* == *'WarnWeakCrypto=no'* ]]
STUB
assert 'WarnWeakCrypto support is probed through ssh -G' __sshp_warn_weak_crypto_supported
probe_args=$(< "$SSH_PROBE_LOG")
assert_contains 'the probe asks for the exact OpenSSH option' "$probe_args" \
    '-G -o WarnWeakCrypto=no sshp-option-probe.invalid'
rm -f "$TEST_STUB_DIR/ssh"
unset SSH_PROBE_LOG

template_policy=$(bash -c 'source "$1"; printf "%s" "$SSHP_WARN_WEAK_CRYPTO"' \
    _ "$config_root/local.sh.example")
assert_equal 'the current local configuration template suppresses the warning' \
    'no' "$template_policy"
template_sync_status=$(bash -c 'source "$1"; printf "%s" "${SSHP_SYNC_STATUS:-yes}"' \
    _ "$config_root/local.sh.example")
assert_equal 'the sync status defaults to enabled' 'yes' "$template_sync_status"

# Keep the remaining policy tests deterministic: they are about sshp's policy,
# not the OpenSSH version installed on the CI runner.
__sshp_warn_weak_crypto_supported() { return 0; }

unset SSHP_WARN_WEAK_CRYPTO
assert 'the default weak-crypto policy parses' __sshp_parse_args user@host
assert_not_contains 'warnings stay enabled by default' "${__sshp_options[*]}" 'WarnWeakCrypto'

SSHP_WARN_WEAK_CRYPTO=no
assert 'warning suppression can be enabled' __sshp_parse_args user@host
assert_contains 'supported clients get the suppression option' "${__sshp_options[*]}" 'WarnWeakCrypto=no'

SSHP_WARN_WEAK_CRYPTO=yes
assert 'warnings can be explicitly enabled' __sshp_parse_args user@host
assert_not_contains 'yes relies on the OpenSSH default' "${__sshp_options[*]}" 'WarnWeakCrypto'

SSHP_WARN_WEAK_CRYPTO=no
__sshp_warn_weak_crypto_supported() { return 1; }
assert 'old OpenSSH clients still parse the destination' __sshp_parse_args user@host
assert_not_contains 'unsupported clients do not receive the option' "${__sshp_options[*]}" 'WarnWeakCrypto'

SSHP_WARN_WEAK_CRYPTO=maybe
assert_status 'an invalid weak-crypto policy is rejected' 2 __sshp_parse_args user@host
unset SSHP_WARN_WEAK_CRYPTO
__sshp_warn_weak_crypto_supported() { return 0; }

unset SSHP_SYNC_STATUS
assert 'the default sync-status policy parses' __sshp_parse_args user@host
SSHP_SYNC_STATUS=no
assert 'sync-status output can be disabled' __sshp_parse_args user@host
SSHP_SYNC_STATUS=maybe
assert_status 'an invalid sync-status policy is rejected' 2 __sshp_parse_args user@host
unset SSHP_SYNC_STATUS

# The animation is terminal-only. In a redirected test process there must be
# no output at all; forcing the terminal predicate lets us exercise the phase
# transitions and final markers without depending on a real PTY in CI.
status_nontty_output=$(bash -c '
    source "$1"
    SSHP_SYNC_STATUS=yes
    __sshp_status_start "sshp: hidden phase..."
    __sshp_status_finish 0 "sshp: hidden result"
' _ "$config_root/ssh-prompt.sh" 2>&1)
assert_equal 'redirected stderr suppresses sync status output' '' "$status_nontty_output"

status_output=$(bash -c '
    source "$1"
    __sshp_status_terminal() { return 0; }
    SSHP_SYNC_STATUS=yes
    __sshp_status_start "sshp: phase one..."
    sleep 0.2
    __sshp_status_start "sshp: phase two..."
    sleep 0.2
    __sshp_status_finish 0 "sshp: finished"
' _ "$config_root/ssh-prompt.sh" 2>&1)
assert_contains 'the spinner renders the first phase' "$status_output" 'sshp: phase one...'
assert_contains 'the spinner renders phase changes' "$status_output" 'sshp: phase two...'
assert_contains 'successful sync status gets a final marker' "$status_output" '[ok] sshp: finished'

status_failure_output=$(bash -c '
    source "$1"
    __sshp_status_terminal() { return 0; }
    SSHP_SYNC_STATUS=yes
    __sshp_status_start "sshp: failing..."
    sleep 0.1
    __sshp_status_finish 1 "sshp: failed"
' _ "$config_root/ssh-prompt.sh" 2>&1)
assert_contains 'failed sync status gets a final marker' "$status_failure_output" '[!!] sshp: failed'

status_disabled_output=$(bash -c '
    source "$1"
    __sshp_status_terminal() { return 0; }
    SSHP_SYNC_STATUS=no
    __sshp_status_start "sshp: disabled..."
    __sshp_status_finish 0 "sshp: disabled result"
' _ "$config_root/ssh-prompt.sh" 2>&1)
assert_equal 'SSHP_SYNC_STATUS=no suppresses even terminal output' '' "$status_disabled_output"

# --- destination and options ----------------------------------------------

assert 'a plain destination parses' __sshp_parse_args user@host
assert_equal 'destination recognised' 'user@host' "$__sshp_target"
assert_equal 'no remote command' 0 "${#__sshp_extra[@]}"

assert 'options before the destination' __sshp_parse_args -v -p 2222 host
assert_equal 'the destination is still found' 'host' "$__sshp_target"
assert_contains 'the flag is passed through' "${__sshp_options[*]}" '-v'
assert_contains 'the option argument stays attached' "${__sshp_options[*]}" '-p 2222'

assert 'an attached option argument' __sshp_parse_args -p2222 host
assert_equal 'attached form parses too' 'host' "$__sshp_target"

assert '--force is consumed' __sshp_parse_args --force host
assert_equal '--force sets the flag' 1 "$__sshp_force"
assert_equal '--force is not passed to ssh' '' "$(printf '%s\n' "${__sshp_options[@]}" | grep -x -- --force || true)"

assert 'double dash ends the options' __sshp_parse_args -v -- host
assert_equal 'the destination after -- is used' 'host' "$__sshp_target"
assert_contains 'options before -- are kept' "${__sshp_options[*]}" '-v'
# The destination check runs after --, so a destination starting with "-" is
# still rejected. Documented here so a change in that rule is noticed.
assert_status 'a dash destination is rejected even after --' 2 __sshp_parse_args -- -weird-host

assert 'a remote command is collected' __sshp_parse_args host uname -a
assert_equal 'first word after the destination' 'uname' "${__sshp_extra[0]}"

assert '--help is recognised' __sshp_parse_args --help
assert_equal '--help sets the flag' 1 "$__sshp_help_requested"

# --- rejected input --------------------------------------------------------

assert_status 'no arguments at all' 2 __sshp_parse_args
assert_status 'only an option' 2 __sshp_parse_args -v
assert_status 'a missing option argument' 2 __sshp_parse_args -p

# --- effective connection identity -----------------------------------------

export SSHP_TEST_LOG="$TEST_TMP/ssh.log"
test_stub ssh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSHP_TEST_LOG"

if [[ ${1-} == -G ]]; then
    shift
    port=22
    user=tester
    config=default
    proxyjump=none
    proxycommand=none
    hostkeyalias=none
    addressfamily=any
    host=''

    while (( $# )); do
        case $1 in
            -p)
                port=$2
                shift 2
                ;;
            -p*)
                port=${1#-p}
                shift
                ;;
            -l)
                user=$2
                shift 2
                ;;
            -l*)
                user=${1#-l}
                shift
                ;;
            -F)
                config=$2
                shift 2
                ;;
            -F*)
                config=${1#-F}
                shift
                ;;
            -J)
                proxyjump=$2
                shift 2
                ;;
            -J*)
                proxyjump=${1#-J}
                shift
                ;;
            -* )
                shift
                ;;
            *)
                host=$1
                shift
                ;;
        esac
    done

    case $config in
        *config-a) hostname=alpha.internal ;;
        *config-b) hostname=beta.internal ;;
        *)
            case $host in
                alias-a|alias-b) hostname=same.internal ;;
                *) hostname=$host ;;
            esac
            ;;
    esac

    printf '%s\n' \
        "host $host" \
        "hostname $hostname" \
        "user $user" \
        "port $port" \
        "addressfamily $addressfamily" \
        "proxyjump $proxyjump" \
        "proxycommand $proxycommand" \
        "hostkeyalias $hostkeyalias" \
        'serveraliveinterval 0'
    exit 0
fi

# Sync and login calls succeed without touching the network. The sync call may
# receive a tar archive on stdin; exiting is enough for this cache-level test.
exit 0
STUB

identity_alias_a=$(__sshp_connection_identity alias-a)
identity_alias_b=$(__sshp_connection_identity alias-b)
assert_equal 'aliases resolving to the same endpoint share an identity' \
    "$identity_alias_a" "$identity_alias_b"

identity_port_1=$(__sshp_connection_identity host -p 2201)
identity_port_2=$(__sshp_connection_identity host -p 2202)
assert_status 'different effective ports produce different identities' 1 \
    test "$identity_port_1" = "$identity_port_2"

: > "$TEST_TMP/config-a"
: > "$TEST_TMP/config-b"
identity_config_a=$(__sshp_connection_identity host -F "$TEST_TMP/config-a")
identity_config_b=$(__sshp_connection_identity host -F "$TEST_TMP/config-b")
assert_status 'different effective HostName values produce different identities' 1 \
    test "$identity_config_a" = "$identity_config_b"

identity_jump_a=$(__sshp_connection_identity host -J jump-a)
identity_jump_b=$(__sshp_connection_identity host -J jump-b)
assert_status 'different ProxyJump routes produce different identities' 1 \
    test "$identity_jump_a" = "$identity_jump_b"

# Exercise the complete state-file path, not just the helper. A repeated
# connection must reuse one state entry; a different effective port must not.
rm -f "$SSHP_TEST_LOG"
assert 'first connection syncs successfully' sshp -p 2201 cache-host
state_count=$(find "$HOME/.cache/sshp" -type f -name 'connection-v1_*.state' | wc -l | tr -d ' ')
assert_equal 'the first endpoint creates one connection-aware state file' 1 "$state_count"

assert 'the same effective connection reuses its cache state' sshp -p 2201 cache-host
state_count=$(find "$HOME/.cache/sshp" -type f -name 'connection-v1_*.state' | wc -l | tr -d ' ')
assert_equal 'a cache hit does not create another state file' 1 "$state_count"

assert 'a second port syncs independently' sshp -p 2202 cache-host
state_count=$(find "$HOME/.cache/sshp" -type f -name 'connection-v1_*.state' | wc -l | tr -d ' ')
assert_equal 'different effective ports keep separate cache state' 2 "$state_count"

assert 'config-a gets its own cache state' sshp -F "$TEST_TMP/config-a" cache-host
config_state_count=$(find "$HOME/.cache/sshp" -type f -name 'connection-v1_*.state' | wc -l | tr -d ' ')
assert 'config-b syncs independently' sshp -F "$TEST_TMP/config-b" cache-host
state_count=$(find "$HOME/.cache/sshp" -type f -name 'connection-v1_*.state' | wc -l | tr -d ' ')
assert_equal 'configs resolving the same alias differently keep separate state' \
    $((config_state_count + 1)) "$state_count"

# Two destination strings that ssh -G resolves identically intentionally share
# state: the cache follows the effective endpoint rather than the spelling.
assert 'the first alias syncs' sshp alias-a
alias_state_count=$(find "$HOME/.cache/sshp" -type f -name 'connection-v1_*.state' | wc -l | tr -d ' ')
assert 'the equivalent alias uses the same state' sshp alias-b
state_count=$(find "$HOME/.cache/sshp" -type f -name 'connection-v1_*.state' | wc -l | tr -d ' ')
assert_equal 'equivalent aliases do not duplicate state' "$alias_state_count" "$state_count"

# A real sync shows a final status marker when stderr is a terminal, while a
# cache hit remains completely quiet and proceeds directly to the login call.
status_terminal_definition=$(declare -f __sshp_status_terminal)
__sshp_status_terminal() { return 0; }
SSHP_SYNC_STATUS=yes
status_first_sync=$(sshp -p 2299 status-host 2>&1)
status_cached_sync=$(sshp -p 2299 status-host 2>&1)
eval "$status_terminal_definition"
unset SSHP_SYNC_STATUS
assert_contains 'a cache miss reports a successful synchronization' \
    "$status_first_sync" '[ok] sshp: prompt synchronized'
assert_equal 'a cache hit emits no synchronization status' '' "$status_cached_sync"

# --- staged remote publication --------------------------------------------

# Execute the real remote heredoc in a throwaway HOME. A remote syntax failure
# must happen in the staging directory and leave the previously published tree
# untouched; the next successful sync must then replace it as one validated
# directory tree.
remote_home="$TEST_TMP/remote-home"
remote_bin="$TEST_TMP/remote-bin"
mkdir -p "$remote_home/.cache/ssh-prompt" "$remote_bin"
printf 'old prompt\n' > "$remote_home/.cache/ssh-prompt/prompt.sh"

real_bash=$(command -v bash)
export SSHP_REMOTE_HOME="$remote_home" SSHP_REMOTE_BIN="$remote_bin" SSHP_REAL_BASH="$real_bash"

cat > "$remote_bin/bash" <<'STUB'
#!/bin/sh
if [ "${1-}" = -n ]; then
    case ${2-} in
        */prompt.sh) exit 42 ;;
    esac
fi
exec "$SSHP_REAL_BASH" "$@"
STUB
chmod +x "$remote_bin/bash"

test_stub ssh <<'STUB'
#!/usr/bin/env bash
if [[ ${1-} == -G ]]; then
    cat <<'CONFIG'
host atomic-host
hostname atomic.internal
user tester
port 22
addressfamily any
proxyjump none
proxycommand none
hostkeyalias none
CONFIG
    exit 0
fi

case " $* " in
    *' -T '*)
        script=${!#}
        HOME="$SSHP_REMOTE_HOME" PATH="$SSHP_REMOTE_BIN:$PATH" \
            "$SSHP_REAL_BASH" -c "$script"
        exit $?
        ;;
esac

# Login connection after a successful sync.
exit 0
STUB

assert_status 'a staged remote syntax failure aborts the sync' 1 \
    sshp --force atomic-host
assert_file 'a failed staged sync preserves the live prompt tree' \
    "$remote_home/.cache/ssh-prompt/prompt.sh" 'old prompt'
assert_equal 'failed staging is cleaned up' '' \
    "$(compgen -G "$remote_home/.cache/.ssh-prompt.new.*" || true)"

rm -f "$remote_bin/bash"
assert 'a valid staged remote tree is published successfully' sshp --force atomic-host
assert 'the published prompt matches the local source' \
    cmp -s "$config_root/prompt.sh" "$remote_home/.cache/ssh-prompt/prompt.sh"
assert_equal 'successful publication leaves no old-tree backup behind' '' \
    "$(compgen -G "$remote_home/.cache/.ssh-prompt.old.*" || true)"

unset SSHP_REMOTE_HOME SSHP_REMOTE_BIN SSHP_REAL_BASH

# --- the function itself ---------------------------------------------------

assert_status 'sshp without a destination' 2 sshp
assert_status 'sshp with a remote command' 2 sshp host uname -a

remote_command_error=$(sshp host uname -a 2>&1)
assert_contains 'the error points at plain ssh' "$remote_command_error" 'Use "ssh host uname ..."'

assert_status 'sshp --help succeeds' 0 sshp --help
help_output=$(sshp --help 2>&1)
assert_contains 'help shows the usage line' "$help_output" 'Usage: sshp'
assert_contains 'help mentions --force' "$help_output" '--force'

# A missing sync file has to be caught before anything is copied.
missing_root="$TEST_TMP/empty-root"
mkdir -p "$missing_root"
missing_error=$(BASH_CONFIG_ROOT=$missing_root sshp host 2>&1)
assert_status 'a missing sync file aborts' 1 env BASH_CONFIG_ROOT="$missing_root" bash -c \
    "source '$config_root/ssh-prompt.sh'; sshp host"
assert_contains 'the missing file is named' "$missing_error" 'prompt.sh is missing'

# --- ssh is deliberately left alone ---------------------------------------

assert_equal 'ssh is not redefined as a function' '' "$(type -t ssh | grep -x function || true)"
assert_status 'no ssh alias is installed' 1 alias ssh

pass 'option/destination split, --force, --, remote command rejection, missing sync files'
