#!/usr/bin/env bash

# Regression test for __ssh_resolve_table in bashrc.d/lib/ssh-resolve.sh, the
# shared body behind ssh-resolve-ips and ssh-resolve-hosts.
#
# Before those two commands were merged, this code existed twice and neither
# copy was covered: tests/ssh-resolve.sh only exercises paths that return
# before any lookup. The table is driven here with a stubbed ssh -G and
# pre-seeded DNS caches, so the test stays offline.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='ssh-resolve-table'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

cat > "$HOME/.ssh/config" <<'CONFIG'
Host web01
    HostName 10.0.0.1
    User deploy
Host 192.168.5.5
    User root
Host legacy
    HostName legacy.example.com
Host *.wild
    HostName 172.16.0.9
CONFIG

cat > "$HOME/.ssh/known_hosts" <<'KNOWN'
# a comment line

10.0.0.1 ssh-ed25519 AAAAKEY1
[2001:db8::5]:2222,alt.example.com ssh-rsa AAAAKEY2
|1|aGFzaA==|aGFzaA== ssh-ed25519 AAAAKEY3
@cert-authority ca.example.com ssh-rsa AAAAKEY4
direct.example.com,10.0.0.1 ecdsa-sha2-nistp256 AAAAKEY5
KNOWN

# ssh -G opens no connection; the stub answers for the aliases the scanner finds.
test_stub ssh <<'STUB'
#!/usr/bin/env bash
target=${!#}
case $target in
    web01)       printf 'hostname 10.0.0.1\nuser deploy\nport 22\n' ;;
    legacy)      printf 'hostname legacy.example.com\nuser deploy\nport 22\n' ;;
    192.168.5.5) printf 'hostname 192.168.5.5\nuser root\nport 22\n' ;;
    *)           printf 'hostname %s\nuser deploy\nport 22\n' "$target" ;;
esac
STUB

# shellcheck source=bashrc.d/ssh-tools.sh
source bashrc.d/ssh-tools.sh

# Pre-seed both caches so no resolver backend is ever called. \x1e is the
# sentinel the lookups store for a failed answer.
__ssh_resolve_ips_dns_cache[10.0.0.1]='ptr-one.example.com'
__ssh_resolve_ips_dns_cache[192.168.5.5]=$'\x1e'
__ssh_resolve_hosts_dns_cache[legacy.example.com]='198.51.100.4'

# Strip the SGR sequences; the columns are what matters here.
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- ssh-resolve-ips -------------------------------------------------------

ips=$(ssh_resolve_ips | plain)

assert_contains 'the IP header comes first' "$ips" 'IP'
assert_contains 'the value column is the hostname' "$ips" 'HOSTNAME'
assert_contains 'a config alias is credited' "$ips" '10.0.0.1'
assert_contains 'the PTR record is shown' "$ips" 'ptr-one.example.com'
assert_contains 'both known_hosts lines are merged onto one IP' "$ips" '3,7'
assert_contains 'an IP used as a Host token is listed' "$ips" '192.168.5.5'
assert_contains 'a missing PTR record shows a dash' "$ips" '192.168.5.5  -'
assert_contains 'an IP behind a wildcard Host keeps a file reference' \
    "$ips" '~/.ssh/config:9'
assert_contains 'a bracketed IPv6 target is unwrapped' "$ips" '2001:db8::5'
assert_not_contains 'hashed entries cannot be traced back' "$ips" '|1|'
assert_not_contains 'hostnames stay out of the IP table' "$ips" 'legacy.example.com'

# --- ssh-resolve-hosts -----------------------------------------------------

hosts=$(ssh_resolve_hosts | plain)

assert_contains 'the hostname header comes first' "$hosts" 'HOSTNAME'
assert_contains 'a resolved name shows its address' "$hosts" '198.51.100.4'
assert_contains 'a name behind a marker entry is listed' "$hosts" 'ca.example.com'
assert_contains 'a name from a multi-name line is listed' "$hosts" 'alt.example.com'
assert_not_contains 'IP literals stay out of the hostname table' "$hosts" '10.0.0.1'
assert_not_contains 'wildcard patterns are never keys' "$hosts" '*.wild'

# --- filter and empty results ---------------------------------------------

filtered=$(ssh_resolve_ips ptr-one | plain)
assert_contains 'the filter matches the value column too' "$filtered" '10.0.0.1'
assert_not_contains 'the filter drops everything else' "$filtered" '192.168.5.5'

filtered=$(ssh_resolve_hosts LEGACY | plain)
assert_contains 'the filter ignores case' "$filtered" 'legacy.example.com'
assert_not_contains 'the filter is applied to hostnames as well' "$filtered" 'ca.example.com'

empty=$(ssh_resolve_ips nomatchxyz | plain)
assert_contains 'the header is printed even without matches' "$empty" 'KNOWN_HOSTS'
assert_contains 'the empty message names the filter' "$empty" 'nomatchxyz'
assert_contains 'the empty message names the right noun' "$empty" 'No IP entries found'

empty=$(ssh_resolve_hosts nomatchxyz | plain)
assert_contains 'each command brings its own noun' "$empty" 'No hostnames found'

# --- caching ---------------------------------------------------------------

# --refresh drops the DNS results only, so the seeded PTR record disappears
# while the table itself is rebuilt from the same files.
__ssh_resolve_ips_cache_invalidate
after=$(ssh_resolve_ips | plain)
assert_not_contains 'refresh discards the DNS cache' "$after" 'ptr-one.example.com'
assert_contains 'refresh keeps the inventory' "$after" '10.0.0.1'

pass 'the shared table: columns, merging, filter, empty results, cache'
