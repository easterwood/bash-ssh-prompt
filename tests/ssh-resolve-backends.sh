#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for the DNS backend layer of bashrc.d/lib/ssh-resolve-ips.sh
# and bashrc.d/lib/ssh-resolve-hosts.sh.
#
# tests/ssh-resolve.sh stops before any lookup and tests/ssh-resolve-table.sh
# pre-seeds the caches, so the backend chain itself -- five external tools per
# direction, each with its own awk parser over that tool's output format -- was
# the one part of the resolvers nothing covered. It is also the part most
# likely to break silently, because getent, dig, host, nslookup and PowerShell
# word their answers differently on every platform the project targets.
#
# Every backend is stubbed, so the test stays offline. The stubs also record
# their invocations, which is what lets the fallback order be asserted instead
# of only the final result.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='ssh-resolve-backends'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

# shellcheck source=bashrc.d/ssh-tools.sh
source bashrc.d/ssh-tools.sh

# --- backend stubs ---------------------------------------------------------

# One stub body for all five tools. It appends its invocation to a call log and
# answers from a fixture file, so a scenario is set up by writing fixtures
# rather than by rewriting stubs.
#
# The fixture is looked up as "<tool>.<last argument>.out" first and
# "<tool>.out" second. That distinguishes the two dig calls the forward
# resolver makes ("dig +short NAME A" and "... AAAA") without a tool-specific
# stub. A missing fixture means "this backend has nothing to say": it exits 1
# with no output, which is exactly how an installed-but-unhelpful resolver
# behaves.
RESOLVE_STUB_STATE="$TEST_TMP/backends"
mkdir -p "$RESOLVE_STUB_STATE" || fail 'could not create the stub state directory'
export RESOLVE_STUB_STATE

for tool in getent dig host nslookup powershell.exe; do
    test_stub "$tool" <<'STUB'
#!/usr/bin/env bash
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$RESOLVE_STUB_STATE/calls"

if [[ -r "$RESOLVE_STUB_STATE/$tool.sleep" ]]; then
    IFS= read -r seconds < "$RESOLVE_STUB_STATE/$tool.sleep"
    sleep "$seconds"
fi

(( $# )) || exit 1
last=${!#}
for fixture in "$RESOLVE_STUB_STATE/$tool.$last.out" "$RESOLVE_STUB_STATE/$tool.out"; do
    [[ -r $fixture ]] || continue
    cat -- "$fixture"
    exit 0
done
exit 1
STUB
done

# Removes every fixture and the call log, so each scenario starts from
# "all five tools are installed and none of them answers".
backends_reset() {
    rm -f -- "$RESOLVE_STUB_STATE"/*.out "$RESOLVE_STUB_STATE"/*.sleep \
        "$RESOLVE_STUB_STATE/calls"
    : > "$RESOLVE_STUB_STATE/calls"
}

# backend_answer NAME  <<'EOF' ... EOF
backend_answer() {
    cat > "$RESOLVE_STUB_STATE/$1.out" || fail "could not write the fixture $1"
}

backend_calls() {
    [[ -r "$RESOLVE_STUB_STATE/calls" ]] || return 0
    cat -- "$RESOLVE_STUB_STATE/calls"
}

backend_call_count() {
    local count=0 line
    while IFS= read -r line; do
        [[ $line == "$1 "* ]] || continue
        ((count += 1))
    done < "$RESOLVE_STUB_STATE/calls"
    printf '%s\n' "$count"
}

# --- reverse direction: the backend chain ----------------------------------

# getent is tried first. Its hosts output carries the address in field one and
# the canonical name in field two.
backends_reset
backend_answer getent <<'OUT'
10.0.0.1        getent-host.example.com getent-alias
OUT
reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.1 3)
assert_equal 'getent answers the PTR lookup' 'getent-host.example.com' "$reply"
assert_equal 'a later backend is not consulted after getent' 0 "$(backend_call_count dig)"

# A trailing dot belongs to the wire format, not to the column.
backends_reset
backend_answer getent <<'OUT'
10.0.0.1        getent-host.example.com.
OUT
reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.1 3)
assert_equal 'the PTR trailing dot is stripped' 'getent-host.example.com' "$reply"

# dig is second. "+short -x" prints the bare PTR record.
backends_reset
backend_answer dig <<'OUT'
dig-host.example.com.
OUT
reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.1 3)
assert_equal 'dig answers when getent stays silent' 'dig-host.example.com' "$reply"
assert_contains 'dig is asked for the reverse record' "$(backend_calls)" 'dig +short -x 10.0.0.1'
assert_equal 'getent is still tried first' 1 "$(backend_call_count getent)"
assert_equal 'host is not reached' 0 "$(backend_call_count host)"

# host is third. Its answer is a full sentence; only the last field counts.
backends_reset
backend_answer host <<'OUT'
1.0.0.10.in-addr.arpa domain name pointer host-host.example.com.
OUT
reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.1 3)
assert_equal 'host answers when getent and dig stay silent' \
    'host-host.example.com' "$reply"

# PowerShell is fourth and is the Git Bash fallback. It emits CRLF.
backends_reset
printf 'ps-host.example.com\r\n' > "$RESOLVE_STUB_STATE/powershell.exe.out"
reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.1 3)
assert_equal 'PowerShell answers and its CR is stripped' 'ps-host.example.com' "$reply"
assert_contains 'PowerShell is called without a profile' \
    "$(backend_calls)" 'powershell.exe -NoProfile -NonInteractive -Command'
assert_contains 'the PowerShell script carries the IP' "$(backend_calls)" "GetHostEntry('10.0.0.1')"

# nslookup is last. Both of its spellings are parsed.
backends_reset
backend_answer nslookup <<'OUT'
Server:		127.0.0.53
Address:	127.0.0.53#53

1.0.0.10.in-addr.arpa	name = nslookup-host.example.com.
OUT
reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.1 3)
assert_equal 'nslookup "name =" is parsed' 'nslookup-host.example.com' "$reply"

backends_reset
backend_answer nslookup <<'OUT'
Name:    nslookup-name.example.com
Address: 10.0.0.1
OUT
reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.1 3)
assert_equal 'the nslookup "Name:" spelling is parsed' 'nslookup-name.example.com' "$reply"

# Every backend installed, none of them with an answer.
backends_reset
assert_status 'an unresolvable IP fails' 1 __ssh_resolve_ips_lookup_uncached 10.0.0.1 3
calls=$(backend_calls)
assert_contains 'getent was tried' "$calls" 'getent hosts 10.0.0.1'
assert_contains 'dig was tried' "$calls" 'dig +short -x 10.0.0.1'
assert_contains 'host was tried' "$calls" 'host 10.0.0.1'
assert_contains 'PowerShell was tried' "$calls" 'powershell.exe'
assert_contains 'nslookup was tried' "$calls" 'nslookup 10.0.0.1'

# --- forward direction: the backend chain ----------------------------------

# getent ahosts repeats an address once per socket type.
backends_reset
backend_answer getent <<'OUT'
198.51.100.4    STREAM fwd.example.com
198.51.100.4    DGRAM
198.51.100.4    RAW
2001:db8::4     STREAM fwd.example.com
OUT
reply=$(__ssh_resolve_hosts_lookup_uncached fwd.example.com 3 | tr '\n' ' ')
assert_contains 'getent ahosts yields the IPv4 address' "$reply" '198.51.100.4'
assert_contains 'getent ahosts yields the IPv6 address' "$reply" '2001:db8::4'
assert_equal 'no later backend runs after getent' 0 "$(backend_call_count dig)"

# dig is asked for A and AAAA separately.
backends_reset
backend_answer dig.A <<'OUT'
198.51.100.5
OUT
backend_answer dig.AAAA <<'OUT'
2001:db8::5
OUT
reply=$(__ssh_resolve_hosts_lookup_uncached fwd.example.com 3 | tr '\n' ' ')
assert_contains 'dig A is used' "$reply" '198.51.100.5'
assert_contains 'dig AAAA is used' "$reply" '2001:db8::5'
assert_equal 'dig is called once per record type' 2 "$(backend_call_count dig)"

backends_reset
backend_answer host <<'OUT'
fwd.example.com has address 198.51.100.6
fwd.example.com has IPv6 address 2001:db8::6
OUT
reply=$(__ssh_resolve_hosts_lookup_uncached fwd.example.com 3 | tr '\n' ' ')
assert_contains 'host yields the IPv4 address' "$reply" '198.51.100.6'
assert_contains 'host yields the IPv6 address' "$reply" '2001:db8::6'

backends_reset
printf '198.51.100.7\r\n2001:db8::7\r\n' > "$RESOLVE_STUB_STATE/powershell.exe.out"
reply=$(__ssh_resolve_hosts_lookup_uncached fwd.example.com 3 | tr '\n' ' ')
assert_contains 'PowerShell yields the IPv4 address' "$reply" '198.51.100.7'
assert_contains 'PowerShell yields the IPv6 address' "$reply" '2001:db8::7'
assert_contains 'the PowerShell script carries the name' \
    "$(backend_calls)" "GetHostAddresses('fwd.example.com')"

# The resolver's own address is printed before the answer section and must not
# be mistaken for a result.
backends_reset
backend_answer nslookup <<'OUT'
Server:		127.0.0.53
Address:	127.0.0.53#53

Non-authoritative answer:
Name:	fwd.example.com
Address: 198.51.100.8
Address: 2001:db8::8
OUT
reply=$(__ssh_resolve_hosts_lookup_uncached fwd.example.com 3 | tr '\n' ' ')
assert_contains 'nslookup yields the answer address' "$reply" '198.51.100.8'
assert_contains 'nslookup yields the IPv6 answer address' "$reply" '2001:db8::8'
assert_not_contains 'the resolver address itself is skipped' "$reply" '127.0.0.53'

backends_reset
assert_status 'an unresolvable name fails' 1 \
    __ssh_resolve_hosts_lookup_uncached fwd.example.com 3

# --- forward direction: normalisation --------------------------------------

# The forward lookup wrapper filters, deduplicates and orders what a backend
# returned. Anything that is not an IP literal is dropped, whatever produced
# it.
backends_reset
__ssh_resolve_hosts_cache_invalidate
backend_answer getent <<'OUT'
2001:db8::9     STREAM fwd.example.com
198.51.100.9    STREAM fwd.example.com
198.51.100.9    DGRAM
198.51.100.10   STREAM
not-an-address  STREAM
999.1.1.1       STREAM
OUT
assert 'the forward lookup succeeds' __ssh_resolve_hosts_lookup fwd.example.com 3
assert_equal 'addresses are deduplicated and IPv4 is ordered first' \
    '198.51.100.9, 198.51.100.10, 2001:db8::9' \
    "$__ssh_resolve_hosts_lookup_result"

# A backend that answers with nothing but junk counts as a failure.
backends_reset
__ssh_resolve_hosts_cache_invalidate
backend_answer getent <<'OUT'
not-an-address  STREAM junk.example.com
OUT
assert_status 'a junk-only answer fails' 1 __ssh_resolve_hosts_lookup junk.example.com 3
assert_equal 'a failed lookup clears the result variable' '' \
    "$__ssh_resolve_hosts_lookup_result"

# --- the caching wrappers --------------------------------------------------

backends_reset
__ssh_resolve_ips_cache_invalidate
backend_answer getent <<'OUT'
10.0.0.2        cached-host.example.com
OUT
assert 'the first PTR lookup succeeds' __ssh_resolve_ips_lookup 10.0.0.2 3
assert_equal 'the first lookup returns the PTR record' \
    'cached-host.example.com' "$__ssh_resolve_ips_lookup_result"
assert_equal 'the first lookup consults a backend' 1 "$(backend_call_count getent)"

assert 'the second PTR lookup succeeds' __ssh_resolve_ips_lookup 10.0.0.2 3
assert_equal 'the cached lookup returns the same record' \
    'cached-host.example.com' "$__ssh_resolve_ips_lookup_result"
assert_equal 'the cached lookup consults no backend' 1 "$(backend_call_count getent)"

# A negative answer is cached as well, otherwise every unreachable entry would
# pay the full five-backend timeout on every call.
backends_reset
assert_status 'an unresolvable IP fails through the wrapper' 1 \
    __ssh_resolve_ips_lookup 10.0.0.3 3
negative_calls=$(backend_call_count getent)
assert_status 'the repeated failure still fails' 1 __ssh_resolve_ips_lookup 10.0.0.3 3
assert_equal 'a negative result is cached too' \
    "$negative_calls" "$(backend_call_count getent)"
assert_equal 'the negative sentinel is stored' $'\x1e' \
    "${__ssh_resolve_ips_dns_cache["10.0.0.3"]-}"

# --refresh drops the DNS results, so the next call asks again.
backends_reset
backend_answer getent <<'OUT'
10.0.0.2        changed-host.example.com
OUT
__ssh_resolve_ips_cache_invalidate
assert 'the lookup after an invalidation succeeds' __ssh_resolve_ips_lookup 10.0.0.2 3
assert_equal 'invalidation makes the backend run again' \
    'changed-host.example.com' "$__ssh_resolve_ips_lookup_result"

backends_reset
__ssh_resolve_hosts_cache_invalidate
backend_answer getent <<'OUT'
198.51.100.11   STREAM cached.example.com
OUT
assert 'the first forward lookup succeeds' __ssh_resolve_hosts_lookup cached.example.com 3
assert 'the second forward lookup succeeds' __ssh_resolve_hosts_lookup cached.example.com 3
assert_equal 'the forward lookup caches as well' 1 "$(backend_call_count getent)"
assert_equal 'the cached forward result survives' '198.51.100.11' \
    "$__ssh_resolve_hosts_lookup_result"

# --- the timeout wrapper ---------------------------------------------------

# Without the timeout binary the wrapper runs the backend unguarded, which is
# documented behaviour and nothing this test can assert.
if command -v timeout >/dev/null 2>&1; then
    backends_reset
    printf '5\n' > "$RESOLVE_STUB_STATE/getent.sleep"
    backend_answer getent <<'OUT'
10.0.0.4        too-slow.example.com
OUT
    backend_answer dig <<'OUT'
fast-host.example.com.
OUT
    started=$SECONDS
    reply=$(__ssh_resolve_ips_lookup_uncached 10.0.0.4 1)
    elapsed=$((SECONDS - started))
    assert_equal 'a hanging backend is cut off and the chain continues' \
        'fast-host.example.com' "$reply"
    assert 'the hanging backend did not run to completion' test "$elapsed" -lt 4
fi

# --- the token extractors --------------------------------------------------

# Which tokens each command claims is the other half of the split between the
# two resolvers, and it decides what ever reaches a backend.
backends_reset

assert_status 'a plain IPv4 token is an IP key' 0 __ssh_resolve_ips_extract_ip 10.0.0.1
assert_equal 'the IPv4 key is the address' '10.0.0.1' \
    "$(__ssh_resolve_ips_extract_ip 10.0.0.1)"
assert_equal 'a bracketed IPv6 token is unwrapped' '2001:db8::5' \
    "$(__ssh_resolve_ips_extract_ip '[2001:db8::5]:2222')"
assert_equal 'a bracketed IPv4 token is unwrapped' '10.0.0.1' \
    "$(__ssh_resolve_ips_extract_ip '[10.0.0.1]:2222')"
assert_status 'a hostname is not an IP key' 1 \
    __ssh_resolve_ips_extract_ip host.example.com

assert_equal 'a hostname token is a name key' 'host.example.com' \
    "$(__ssh_resolve_hosts_extract_name host.example.com)"
assert_equal 'a bracketed hostname is unwrapped' 'host.example.com' \
    "$(__ssh_resolve_hosts_extract_name '[host.example.com]:2222')"
assert_equal 'a trailing dot is stripped from a name key' 'host.example.com' \
    "$(__ssh_resolve_hosts_extract_name 'host.example.com.')"
assert_status 'an IP literal is not a name key' 1 \
    __ssh_resolve_hosts_extract_name 10.0.0.1
assert_status 'a bracketed IP literal is not a name key' 1 \
    __ssh_resolve_hosts_extract_name '[2001:db8::5]:2222'
assert_status 'a wildcard pattern is not a name key' 1 \
    __ssh_resolve_hosts_extract_name '*.example.com'
assert_status 'a marker is not a name key' 1 \
    __ssh_resolve_hosts_extract_name '@cert-authority'

assert_equal 'no backend is reached by an extractor' '' "$(backend_calls)"

pass 'all five DNS backends per direction, fallback order, caching, timeout, extractors'
