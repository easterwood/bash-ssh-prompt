#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for bashrc.d/lib/ssh-config.sh, the config scanner shared by
# known-hosts, ssh-nr and the completions.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='ssh-config'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

# shellcheck source=bashrc.d/lib/ssh-config.sh
source bashrc.d/lib/ssh-config.sh

config="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh/conf.d" "$HOME/elsewhere"

cat > "$config" <<'EOF'
# leading comment
Include conf.d/*.conf
Include ~/elsewhere/tilde.conf

Host web01 web02
    HostName web.example.com
    User deploy

Host "quoted"
    HostName quoted.example.com

Host *.wildcard bad!name
    User nobody

Host db
    User postgres
    HostName db.example.com

Host inherited          # user comes from Host * below
    HostName inherited.example.com

Host *
    User fallback
EOF

cat > "$HOME/.ssh/conf.d/10-extra.conf" <<'EOF'
Host included
    HostName included.example.com
    User svc
EOF

cat > "$HOME/elsewhere/tilde.conf" <<'EOF'
Host tilde-host
    HostName tilde.example.com
EOF

# A file the glob must not pick up.
printf 'Host ignored\n' > "$HOME/.ssh/conf.d/notes.txt"

__kh_scan_configs "$config" 1
aliases=" ${__kh_scan_aliases[*]} "

# --- concrete aliases ------------------------------------------------------

assert_contains 'first alias of a multi-alias Host line' "$aliases" ' web01 '
assert_contains 'second alias of a multi-alias Host line' "$aliases" ' web02 '
assert_contains 'quoted alias, quotes stripped' "$aliases" ' quoted '
assert_contains 'plain alias' "$aliases" ' db '

# --- patterns that must not become aliases ---------------------------------

assert_not_contains 'wildcard pattern skipped' "$aliases" '*.wildcard'
assert_not_contains 'negation pattern skipped' "$aliases" 'bad!name'
assert_not_contains 'bare Host * skipped' "$aliases" ' * '

# --- Include ---------------------------------------------------------------

assert_contains 'glob Include followed' "$aliases" ' included '
assert_contains '~/ Include followed' "$aliases" ' tilde-host '
assert_not_contains 'glob does not match other extensions' "$aliases" ' ignored '
assert_contains 'include pattern recorded' " ${__kh_scan_include_patterns[*]} " "$HOME/.ssh/conf.d/*.conf"
assert_contains 'included file recorded' " ${__kh_scan_files[*]} " "$HOME/.ssh/conf.d/10-extra.conf"

# --- direct user assignments ----------------------------------------------

assert_equal 'user of a concrete block is direct' 'deploy' "${__kh_scan_alias_direct_user[web01]-}"
assert_equal 'second alias of the block too' 'deploy' "${__kh_scan_alias_direct_user[web02]-}"
assert_equal 'user reaches the HostName as well' 'deploy' "${__kh_scan_target_direct_user[web.example.com]-}"
assert_equal 'user before HostName in the block' 'postgres' "${__kh_scan_target_direct_user[db.example.com]-}"
assert_equal 'user from an included file' 'svc' "${__kh_scan_alias_direct_user[included]-}"

# A user from "Host *" is inherited, not direct — this is what the magenta
# USER column in known-hosts is built on.
assert_equal 'Host * user is not direct' '' "${__kh_scan_alias_direct_user[inherited]-}"
assert_equal 'Host * does not become a direct target user' '' "${__kh_scan_target_direct_user[inherited.example.com]-}"

# --- repeated scans --------------------------------------------------------

count_before=${#__kh_scan_aliases[@]}
__kh_scan_configs "$config" 1
assert_equal 'a second scan does not accumulate' "$count_before" "${#__kh_scan_aliases[@]}"

# --- missing file ----------------------------------------------------------

assert_status 'a missing config is not an error' 0 __kh_scan_configs "$HOME/.ssh/does-not-exist" 1
assert_equal 'a missing config yields no aliases' 0 "${#__kh_scan_aliases[@]}"

# --- shared inventory cache -------------------------------------------------

known="$HOME/.ssh/known_hosts"
printf 'inventory.example.com ssh-ed25519 AAAAINVENTORY\n' > "$known"
SSH_CONFIG_TEST_CALLS="$TEST_TMP/ssh-config.calls"
: > "$SSH_CONFIG_TEST_CALLS"
export SSH_CONFIG_TEST_CALLS

test_stub ssh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${!#}" >> "$SSH_CONFIG_TEST_CALLS"
target=${!#}
user=default
hostname=$target
case $target in
    web01|web02)
        hostname=web.example.com
        user=$(awk '/^Host web01 web02$/{in_block=1; next} in_block && /^[[:space:]]*User[[:space:]]+/{print $2; exit}' "$HOME/.ssh/config")
        ;;
esac
printf 'hostname %s\nuser %s\nport 22\nhostkeyalias none\n' "$hostname" "$user"
STUB

__ssh_inventory_ensure "$known" "$config"
inventory_generation=$__ssh_inventory_generation
assert_contains 'the inventory exposes user aliases' " ${__ssh_inventory_user_aliases[*]} " ' web01 '
assert_contains 'the inventory tracks included user files' " ${__ssh_inventory_user_files[*]} " "$HOME/.ssh/conf.d/10-extra.conf"

__ssh_inventory_ensure "$known" "$config"
assert_equal 'an unchanged inventory keeps its generation' "$inventory_generation" "$__ssh_inventory_generation"

__ssh_inventory_target_dump "$config" web01 1
first_dump=$REPLY
__kh_ssh_config_field "$first_dump" user
assert_equal 'the target cache stores ssh -G output' deploy "$REPLY"
assert_equal 'the first target lookup executes ssh once' 1 "$(wc -l < "$SSH_CONFIG_TEST_CALLS" | tr -d ' ')"

__ssh_inventory_target_dump "$config" web01 1
assert_equal 'a repeated target lookup reuses ssh -G output' 1 "$(wc -l < "$SSH_CONFIG_TEST_CALLS" | tr -d ' ')"

sed -i 's/User deploy/User changed/' "$config"
__ssh_inventory_ensure "$known" "$config"
assert_greater 'editing the main config advances the inventory generation' \
    "$__ssh_inventory_generation" "$inventory_generation"
inventory_generation=$__ssh_inventory_generation
__ssh_inventory_target_dump "$config" web01 1
__kh_ssh_config_field "$REPLY" user
assert_equal 'a config edit invalidates cached ssh -G output' changed "$REPLY"
assert_equal 'the target is resolved again after config invalidation' 2 "$(wc -l < "$SSH_CONFIG_TEST_CALLS" | tr -d ' ')"

cat > "$HOME/.ssh/conf.d/20-later.conf" <<'EOF'
Host cache-added
    HostName cache-added.example.com
EOF
__ssh_inventory_ensure "$known" "$config"
assert_greater 'a new Include glob match advances the inventory generation' \
    "$__ssh_inventory_generation" "$inventory_generation"
assert_contains 'a new Include glob match enters the inventory' \
    " ${__ssh_inventory_user_aliases[*]} " ' cache-added '
inventory_generation=$__ssh_inventory_generation

printf 'second.example.com ssh-ed25519 AAAASECOND\n' >> "$known"
__ssh_inventory_ensure "$known" "$config"
assert_greater 'editing known_hosts advances the same inventory generation' \
    "$__ssh_inventory_generation" "$inventory_generation"
assert_contains 'the shared known_hosts snapshot is refreshed' \
    "$__ssh_inventory_known_content" 'second.example.com'

# --- the cache invalidator registry ----------------------------------------

# known-hosts used to name every other module's cache by hand, in two places
# that had drifted apart. Modules register their own invalidator instead, and
# known-hosts just drops whatever is registered.

registry_log=''
__test_cache_one() { registry_log+='one '; }
__test_cache_two() { registry_log+='two '; }

registry_before=${#__ssh_cache_invalidators[@]}
assert_greater 'the shipped modules register their invalidators' \
    "$registry_before" 0
assert_contains 'the inventory registers itself' \
    " ${__ssh_cache_invalidators[*]} " ' __ssh_inventory_invalidate '
assert_equal 'the inventory is dropped before the caches derived from it' \
    '__ssh_inventory_invalidate' "${__ssh_cache_invalidators[0]}"

__ssh_cache_register_invalidator __test_cache_one __test_cache_two
assert_equal 'registering adds one entry per name' \
    "$((registry_before + 2))" "${#__ssh_cache_invalidators[@]}"

__ssh_cache_register_invalidator __test_cache_one
assert_equal 'registering the same name twice is a no-op' \
    "$((registry_before + 2))" "${#__ssh_cache_invalidators[@]}"

# A registered but undefined function must not break the sweep: a test that
# sources a single lib has a partially loaded tree.
__ssh_cache_register_invalidator __test_cache_missing

registry_log=''
assert_status 'a missing invalidator is skipped, not fatal' 0 \
    __ssh_cache_invalidate_all
assert_equal 'every registered invalidator ran, in registration order' \
    'one two ' "$registry_log"

# --- the shared config line tokenizer --------------------------------------

# __kh_parse_config_line is the single place that knows how an ssh_config line
# is spelled. The scanner above and __ssh_resolve_table both go through it, so
# the contract is pinned down here rather than once per consumer.

assert_status 'a blank line is rejected' 1 __kh_parse_config_line ''
assert_status 'a whitespace-only line is rejected' 1 __kh_parse_config_line '   '
assert_status 'a comment-only line is rejected' 1 __kh_parse_config_line '  # Host nope'
assert_status 'an inline comment leaves the keyword' 0 \
    __kh_parse_config_line 'Host web01 # the web server'

__kh_parse_config_line 'Host web01 # the web server'
assert_equal 'an inline comment is stripped' 2 "${#__kh_config_words[@]}"
assert_equal 'the token before an inline comment survives' 'web01' \
    "${__kh_config_words[1]}"

__kh_parse_config_line 'HostName web.example.com'
assert_equal 'the keyword is lowercased' 'hostname' "$__kh_config_keyword"
assert_equal 'the value is the second word' 'web.example.com' \
    "${__kh_config_words[1]}"

__kh_parse_config_line 'HOSTNAME web.example.com'
assert_equal 'an upper-case keyword is lowercased too' 'hostname' "$__kh_config_keyword"

__kh_parse_config_line 'HostName=web.example.com'
assert_equal 'the Keyword=value form yields the keyword' 'hostname' "$__kh_config_keyword"
assert_equal 'the Keyword=value form yields the value' 'web.example.com' \
    "${__kh_config_words[1]}"

__kh_parse_config_line 'ProxyCommand=nc %h %p'
assert_equal 'only the first = is a separator' 'proxycommand' "$__kh_config_keyword"
assert_equal 'a later = stays inside the value' 'nc' "${__kh_config_words[1]}"

__kh_parse_config_line 'HostName "quoted.example.com"'
assert_equal 'surrounding quotes are stripped from a value' 'quoted.example.com' \
    "${__kh_config_words[1]}"

__kh_parse_config_line $'Host crlf01\r'
assert_equal 'a CRLF line ending is stripped' 'crlf01' "${__kh_config_words[1]}"

__kh_parse_config_line '  Host  web01   web02  '
assert_equal 'indentation and repeated spaces collapse' 3 "${#__kh_config_words[@]}"
assert_equal 'the first alias is read' 'web01' "${__kh_config_words[1]}"
assert_equal 'the second alias is read' 'web02' "${__kh_config_words[2]}"

__kh_parse_config_line 'Host web01'
__kh_parse_config_line 'Compression'
assert_equal 'a keyword without a value keeps only itself' 1 "${#__kh_config_words[@]}"
assert_equal 'a rejected line does not leak the previous keyword' 'compression' \
    "$__kh_config_keyword"

assert_status 'legacy ssh-resolve-ips completion file is removed' 1 \
    test -e bashrc.d/completions/ssh-resolve-ips.bash
assert_status 'legacy ssh-resolve-hosts completion file is removed' 1 \
    test -e bashrc.d/completions/ssh-resolve-hosts.bash

pass 'scanner plus shared config/known_hosts inventory, invalidation and ssh -G cache'
