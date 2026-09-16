#!/usr/bin/env bash

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

pass 'aliases, wildcards, quotes, Include with glob and ~, direct vs inherited users'
