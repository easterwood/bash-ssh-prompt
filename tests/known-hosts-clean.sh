#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for "known-hosts --clean", which replaced the separate
# known-hosts-clean command.
#
# ssh, ssh-keygen and ssh-keyscan are replaced by stubs, so the test opens no
# network connection and does not depend on an installed OpenSSH. The stubs are
# synthetic: no real host keys are involved.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='known-hosts --clean'
test_root=$PWD
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

# --- fixtures -------------------------------------------------------------

cat > "$HOME/.ssh/known_hosts" <<'EOF'
# synthetic test data, not real keys
alive.example.com ssh-ed25519 AAAAALIVE
dead.example.com ssh-ed25519 AAAADEAD
|1|TESTSALT|TESTHASH ssh-ed25519 AAAAHASHED
EOF

cat > "$HOME/.ssh/config" <<'EOF'
Host alive
    HostName alive.example.com
    User me

Host dead
    HostName dead.example.com
    User me
EOF

known_hosts_before=$(< "$HOME/.ssh/known_hosts")
config_before=$(< "$HOME/.ssh/config")

test_stub ssh <<'EOF'
#!/usr/bin/env bash
# Only "ssh -G -T DESTINATION" is used by the tools under test.
host=${*: -1}
case $host in
    alive) hostname=alive.example.com ;;
    dead)  hostname=dead.example.com ;;
    *)     hostname=$host ;;
esac
printf 'hostname %s\nuser me\nport 22\nhostkeyalias none\n' "$hostname"
EOF

test_stub ssh-keygen <<'EOF'
#!/usr/bin/env bash
# Only "ssh-keygen -F LOOKUP -f FILE" is used. Exit 1 means: not found.
lookup='' file=''
while (( $# )); do
    case $1 in
        -F) lookup=$2; shift 2 ;;
        -f) file=$2; shift 2 ;;
        *)  shift ;;
    esac
done
[[ -n $lookup && -r $file ]] || exit 1
number=0
status=1
while IFS= read -r line; do
    number=$((number + 1))
    read -r first _ <<< "$line"
    [[ $first == "$lookup" ]] || continue
    printf '# Host %s found: line %d \n%s\n' "$lookup" "$number" "$line"
    status=0
done < "$file"
exit "$status"
EOF

test_stub ssh-keyscan <<'EOF'
#!/usr/bin/env bash
# Exactly one host answers; everything else stays silent, which the cleanup
# reads as unreachable.
host=${*: -1}
[[ $host == alive.example.com ]] || exit 0
printf '%s ssh-ed25519 AAAAALIVE\n' "$host"
EOF

# shellcheck source=bashrc.d/ssh-tools.sh
source bashrc.d/ssh-tools.sh

# --- the old command is gone ---------------------------------------------

assert_status 'known-hosts-clean alias removed' 1 alias known-hosts-clean
assert_status 'ssh-known-hosts-clean alias removed' 1 alias ssh-known-hosts-clean
assert_equal 'ssh_known_hosts_clean function removed' '' "$(type -t ssh_known_hosts_clean)"
assert_equal 'clean completion function removed' '' "$(type -t _ssh_known_hosts_clean_completion)"
assert_equal 'clean implementation available as a helper' 'function' "$(type -t __kh_clean_run)"

# --- help ------------------------------------------------------------------

help_output=$(ssh_known_hosts --help)
assert_contains 'help documents --clean' "$help_output" '--clean'
assert_contains 'help documents --apply' "$help_output" '--apply'
assert_contains 'help still documents --fingerprints' "$help_output" '--fingerprints'
assert_contains 'help names the keyscan timeout' "$help_output" 'SSH_KNOWN_HOSTS_CLEAN_TIMEOUT'

# --- rejected option combinations ------------------------------------------

assert_status '--apply without --clean' 2 ssh_known_hosts --apply
assert_status '--clean with --lines' 2 ssh_known_hosts --clean --lines
assert_status '--clean with --refresh' 2 ssh_known_hosts --clean --refresh
assert_status '--clean with --fingerprints' 2 ssh_known_hosts --clean --fingerprints
assert_status '--clean with a filter' 2 ssh_known_hosts --clean alive
assert_status 'unknown option' 2 ssh_known_hosts --nope

# --- dry run ---------------------------------------------------------------

dry_run=$(ssh_known_hosts --clean)
assert_contains 'reachable host is kept' "$dry_run" 'alive.example.com:22'
assert_contains 'unreachable host is reported' "$dry_run" 'UNREACHABLE -> REMOVE'
assert_contains 'hashed entry is skipped' "$dry_run" 'SKIP    hashed entry'
assert_contains 'stale config alias is reported' "$dry_run" 'CONFIG  REMOVE  dead'
assert_contains 'dry run is announced' "$dry_run" 'DRY RUN'
assert_contains 'dry run points at the new command' "$dry_run" 'known-hosts --clean --apply'
assert_not_contains 'live host is not removed' "$dry_run" 'CONFIG  REMOVE  alive'

assert_file 'dry run leaves known_hosts alone' "$HOME/.ssh/known_hosts" "$known_hosts_before"
assert_file 'dry run leaves the config alone' "$HOME/.ssh/config" "$config_before"

# --- apply -----------------------------------------------------------------

apply_output=$(ssh_known_hosts --clean --apply)
assert_contains 'apply reports the known_hosts backup' "$apply_output" 'Backup known_hosts:'
assert_contains 'apply reports the config backup' "$apply_output" 'Backup SSH config:'

known_hosts_after=$(< "$HOME/.ssh/known_hosts")
config_after=$(< "$HOME/.ssh/config")

assert_contains 'reachable entry survives' "$known_hosts_after" 'alive.example.com ssh-ed25519'
assert_not_contains 'unreachable entry removed' "$known_hosts_after" 'dead.example.com ssh-ed25519'
assert_contains 'hashed entry survives' "$known_hosts_after" '|1|TESTSALT|TESTHASH'
assert_contains 'live alias survives' "$config_after" 'Host alive'
assert_not_contains 'stale alias removed' "$config_after" 'Host dead'
assert_not_contains 'stale block removed entirely' "$config_after" 'dead.example.com'

assert 'known_hosts backup written' \
    compgen -G "$HOME/.ssh/known_hosts.bak.*" >/dev/null
assert 'config backup written' \
    compgen -G "$HOME/.ssh/config.bak.*" >/dev/null

# The caches have to notice the rewritten files.
overview=$(ssh_known_hosts)
assert_contains 'overview still lists the live host' "$overview" 'alive.example.com'
assert_not_contains 'overview drops the removed host' "$overview" 'dead.example.com'

# --- the cache sweep after --apply -----------------------------------------

# --apply and --refresh used to drop different sets of caches: --refresh
# cleared the two DNS caches, --apply did not, and the guards differed. Both
# now sweep whatever the loaded modules registered.
#
# The call must not be wrapped in a command substitution. --apply does its work
# in a subshell already and only the invalidation afterwards runs in this
# shell, so capturing its output would hide exactly what is asserted here.
declare -A __ssh_resolve_ips_dns_cache
declare -A __ssh_resolve_hosts_dns_cache
__ssh_resolve_ips_dns_cache[203.0.113.9]='stale.example.com'
__ssh_resolve_hosts_dns_cache[stale.example.com]='203.0.113.9'
__ssh_completion_cache_ensure
assert_greater 'the completion cache is populated beforehand' \
    "${#__ssh_completion_connect_hosts[@]}" 0
assert 'the inventory is populated beforehand' test -n "$__ssh_inventory_cache_id"

ssh_known_hosts --clean --apply >/dev/null 2>&1

assert_equal 'apply drops the reverse DNS cache' 0 \
    "${#__ssh_resolve_ips_dns_cache[@]}"
assert_equal 'apply drops the forward DNS cache' 0 \
    "${#__ssh_resolve_hosts_dns_cache[@]}"
assert_equal 'apply drops the completion cache' 0 \
    "${#__ssh_completion_connect_hosts[@]}"
assert_equal 'apply drops the shared inventory' '' "$__ssh_inventory_cache_id"

# --refresh drops exactly the same set.
__ssh_resolve_ips_dns_cache[203.0.113.9]='stale.example.com'
__ssh_resolve_hosts_dns_cache[stale.example.com]='203.0.113.9'
__ssh_completion_cache_ensure
generation_before=$__ssh_inventory_generation
ssh_known_hosts --refresh >/dev/null 2>&1

assert_equal 'refresh drops the reverse DNS cache' 0 \
    "${#__ssh_resolve_ips_dns_cache[@]}"
assert_equal 'refresh drops the forward DNS cache' 0 \
    "${#__ssh_resolve_hosts_dns_cache[@]}"
assert_equal 'refresh drops the completion cache' 0 \
    "${#__ssh_completion_connect_hosts[@]}"
# The display rebuilds the inventory on the way out, which is what a new
# generation proves it really was discarded first.
assert_greater 'refresh rebuilds the inventory under a new generation' \
    "$__ssh_inventory_generation" "$generation_before"

# --- the dispatch guard ----------------------------------------------------

# --clean lives in the file ssh-tools.sh sources after known-hosts.sh, so
# known-hosts cannot guard on it at source time the way every other module
# does. Without a call-site guard a partially loaded tree answered with
# "command not found".
guard_output=$(bash -c '
    cd "$1" || exit 1
    source bashrc.d/lib/options.sh
    source bashrc.d/lib/ssh-config.sh
    source bashrc.d/lib/known-hosts.sh
    ssh_known_hosts --clean
' _ "$test_root" 2>&1)
guard_status=$?
assert_equal 'a missing --clean implementation fails cleanly' 1 "$guard_status"
assert_contains 'the error names the missing file' "$guard_output" 'known-hosts-clean.sh'
assert_not_contains 'the shell does not report a missing command' \
    "$guard_output" 'command not found'

# --- completion ------------------------------------------------------------

COMP_WORDS=(known-hosts --clean --a)
COMP_CWORD=2
_ssh_known_hosts_completion
assert_contains 'completion offers --apply after --clean' " ${COMPREPLY[*]} " ' --apply '

COMP_WORDS=(known-hosts --clean '')
COMP_CWORD=2
_ssh_known_hosts_completion
assert_not_contains 'completion offers no hosts after --clean' " ${COMPREPLY[*]} " 'alive'

COMP_WORDS=(known-hosts --c)
COMP_CWORD=1
_ssh_known_hosts_completion
assert_contains 'completion offers --clean itself' " ${COMPREPLY[*]} " ' --clean '

pass 'dry run, apply with backups, the shared cache sweep, rejected combinations, removed alias, completion'
