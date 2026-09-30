#!/usr/bin/env bash

# Test scripts: the sandbox variables (TEST_TMP, TEST_HOME, TEST_STUB_DIR) come
# from tests/lib.sh, the single-quoted strings holding $ are rcfile and bash -c
# payloads that must not expand here, and several helpers are reached only
# through the configuration under test.
# shellcheck disable=SC2154,SC2034,SC2016,SC2317,SC2218,SC2031,SC2088

# Regression test for the completion layer: the shared host cache in
# completions/ssh-hosts.bash and the ssh/sshp completion in completions/ssh.bash.
#
# Completion functions are called directly with COMP_WORDS/COMP_CWORD set, the
# way Readline would call them.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='completion'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

cat > "$HOME/.ssh/config" <<'EOF'
Host web01
    HostName web01.example.com
    User deploy

Host db-prod
    HostName db.example.com
    User postgres

Host *.wildcard
    User nobody
EOF

cat > "$HOME/.ssh/known_hosts" <<'EOF'
direct.example.com ssh-ed25519 AAAADIRECT
[ported.example.com]:2222 ssh-ed25519 AAAAPORT
|1|TESTSALT|TESTHASH ssh-ed25519 AAAAHASHED
EOF

test_stub ssh <<'EOF'
#!/usr/bin/env bash
host=${*: -1}
case $host in
    web01)   hostname=web01.example.com; user=deploy ;;
    db-prod) hostname=db.example.com;    user=postgres ;;
    *)       hostname=$host;             user=me ;;
esac
printf 'hostname %s\nuser %s\nport 22\nhostkeyalias none\n' "$hostname" "$user"
EOF

test_stub ssh-keygen <<'EOF'
#!/usr/bin/env bash
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

# shellcheck source=bashrc.d/ssh-tools.sh
source bashrc.d/ssh-tools.sh

complete_with() {
    local function_name=$1
    shift
    COMP_WORDS=("$@")
    COMP_CWORD=$(( $# - 1 ))
    COMP_LINE="$*"
    COMP_POINT=${#COMP_LINE}
    COMPREPLY=()
    "$function_name"
    printf ' %s \n' "${COMPREPLY[*]-}"
}

# --- the shared cache ------------------------------------------------------

__ssh_completion_cache_ensure "$HOME/.ssh/known_hosts" "$HOME/.ssh/config"
filter_hosts=" ${__ssh_completion_filter_hosts[*]} "
connect_hosts=" ${__ssh_completion_connect_hosts[*]} "

assert_contains 'config aliases are offered as filters' "$filter_hosts" ' web01 '
assert_contains 'known_hosts targets are offered as filters' "$filter_hosts" ' direct.example.com '
assert_contains 'config aliases are connectable' "$connect_hosts" ' web01 '
assert_not_contains 'hashed entries never appear' "$filter_hosts" 'TESTHASH'
assert_not_contains 'wildcard patterns never appear' "$connect_hosts" '*.wildcard'

assert_contains 'the scanned config is recorded' " ${__ssh_completion_config_files[*]} " "$HOME/.ssh/config"

# A second call must not duplicate the entries.
count_before=${#__ssh_completion_filter_hosts[@]}
__ssh_completion_cache_ensure "$HOME/.ssh/known_hosts" "$HOME/.ssh/config"
assert_equal 'the cache is not rebuilt blindly' "$count_before" "${#__ssh_completion_filter_hosts[@]}"

# An edited config has to be noticed without an explicit refresh.
printf '\nHost added-later\n    HostName later.example.com\n' >> "$HOME/.ssh/config"
__ssh_completion_cache_ensure "$HOME/.ssh/known_hosts" "$HOME/.ssh/config"
assert_contains 'an edited config invalidates the cache' \
    " ${__ssh_completion_filter_hosts[*]} " ' added-later '

__ssh_completion_cache_invalidate
assert_equal 'invalidation empties the cache' 0 "${#__ssh_completion_filter_hosts[@]}"

# --- ssh and sshp destinations --------------------------------------------

reply=$(complete_with _ssh_tools_ssh_completion ssh web)
assert_contains 'ssh completes a config alias' "$reply" 'web01'

reply=$(complete_with _ssh_tools_ssh_completion sshp db)
assert_contains 'sshp completes the same aliases' "$reply" 'db-prod'

# Long switches belong to sshp only; native OpenSSH has none.
reply=$(complete_with _ssh_tools_ssh_completion sshp --f)
assert_contains 'sshp offers --force' "$reply" '--force'

reply=$(complete_with _ssh_tools_ssh_completion ssh --f)
assert_equal 'ssh offers no long switches' '  ' "$reply"

# user@host completion starts from the user side as well.
reply=$(complete_with _ssh_tools_ssh_completion ssh 'deploy@')
assert_contains 'a configured user narrows the hosts' "$reply" 'web01'
assert_not_contains 'hosts with another user drop out' "$reply" 'db-prod'

reply=$(complete_with _ssh_tools_ssh_completion ssh 'someone@')
assert_contains 'an unknown user falls back to all hosts' "$reply" 'web01'

# --- known-hosts -----------------------------------------------------------

reply=$(complete_with _ssh_known_hosts_completion known-hosts --)
assert_contains 'known-hosts offers --lines' "$reply" '--lines'
assert_contains 'known-hosts offers --clean' "$reply" '--clean'

reply=$(complete_with _ssh_known_hosts_completion known-hosts web)
assert_contains 'known-hosts completes a filter' "$reply" 'web01'

reply=$(complete_with _ssh_known_hosts_completion known-hosts web01 '')
assert_equal 'no second filter is offered' '  ' "$reply"

reply=$(complete_with _ssh_known_hosts_completion known-hosts --fingerprints '')
assert_equal 'nothing after --fingerprints' '  ' "$reply"

# --- ssh-nr ----------------------------------------------------------------

reply=$(complete_with _ssh_by_number_completion ssh-nr '')
assert_contains 'ssh-nr offers the first target number' "$reply" '1'

reply=$(complete_with _ssh_by_number_completion ssh-nr -)
assert_contains 'ssh-nr offers --list' "$reply" '--list'
assert_contains 'ssh-nr offers --help' "$reply" '--help'

reply=$(complete_with _ssh_by_number_completion ssh-nr 1 '')
assert_equal 'no second number is offered' '  ' "$reply"

# --- the command-line tokeniser --------------------------------------------

# __ssh_completion_parse_line splits COMP_LINE itself, because readline's own
# word splitting does not honour SSH config quoting. The backslash branches
# were unreachable until the case patterns were corrected: '\\' in a pattern
# matches two backslashes, so a single one fell through to the default branch
# and stayed in the token verbatim.
tokens() {
    COMP_LINE=$1
    COMP_POINT=${#COMP_LINE}
    __ssh_completion_parse_line
    printf '[%s]' "${__ssh_completion_line_words[@]}"
}

assert_equal 'a backslash escapes a space' \
    '[ssh][web server][x]' "$(tokens 'ssh web\ server x')"
assert_equal 'a doubled backslash is one literal backslash' \
    '[ssh][a\b][x]' "$(tokens 'ssh a\\b x')"
assert_equal 'a backslash inside double quotes escapes too' \
    '[ssh][a"b][x]' "$(tokens 'ssh "a\"b" x')"
assert_equal 'single quotes keep a backslash literal' \
    "[ssh][a\\b][x]" "$(tokens "ssh 'a\\b' x")"
assert_equal 'plain words are unaffected' \
    '[ssh][web01][x]' "$(tokens 'ssh web01 x')"

# --- the resolvers ---------------------------------------------------------

# Both resolvers share one completion function, registered under both names.
reply=$(complete_with _ssh_resolve_completion ssh-resolve-ips --)
assert_contains 'ssh-resolve-ips offers --refresh' "$reply" '--refresh'

reply=$(complete_with _ssh_resolve_completion ssh-resolve-hosts --)
assert_contains 'ssh-resolve-hosts offers --refresh' "$reply" '--refresh'

reply=$(complete_with _ssh_resolve_completion ssh-resolve-ips --help '')
assert_equal 'no second argument is offered' '  ' "$reply"

assert_equal 'ssh-resolve-ips is registered' '_ssh_resolve_completion' \
    "$(complete -p ssh-resolve-ips | awk '{print $3}')"
assert_equal 'ssh-resolve-hosts shares the registration' '_ssh_resolve_completion' \
    "$(complete -p ssh-resolve-hosts | awk '{print $3}')"

pass 'host cache, invalidation on edit, ssh/sshp destinations, per-command options'
