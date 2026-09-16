#!/usr/bin/env bash

# Regression test for bashrc.d/lib/ssh-by-number.sh (ssh-nr).
#
# sshp is replaced by a function that only records its arguments, so no
# connection is attempted. That also exercises the "function" branch of
# __ssh_by_number_run_sshp; the alias branch is checked separately.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='ssh-nr'
# shellcheck source=tests/lib.sh
source tests/lib.sh
test_sandbox

cat > "$HOME/.ssh/known_hosts" <<'EOF'
plain.example.com ssh-ed25519 AAAAPLAIN
[ported.example.com]:2222 ssh-ed25519 AAAAPORT
@cert-authority *.example.net ssh-ed25519 AAAAMARKER
|1|TESTSALT|TESTHASH ssh-ed25519 AAAAHASHED
EOF

cat > "$HOME/.ssh/config" <<'EOF'
Host aliased
    HostName plain.example.com
    User me
EOF

test_stub ssh <<'EOF'
#!/usr/bin/env bash
host=${*: -1}
case $host in
    aliased) hostname=plain.example.com ;;
    *)       hostname=$host ;;
esac
printf 'hostname %s\nuser me\nport 22\nhostkeyalias none\n' "$hostname"
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

sshp_call=''
sshp() {
    sshp_call="$*"
}

# --- help and --list -------------------------------------------------------

assert_status 'no argument is an error' 2 ssh_by_number
assert_status '--help succeeds' 0 ssh_by_number --help
help_output=$(ssh_by_number --help)
assert_contains 'help names the number argument' "$help_output" 'ssh-nr NR'

list_output=$(ssh_by_number --list)
assert_contains '--list prints the known-hosts table' "$list_output" 'TARGET'
assert_status '--list takes no further arguments' 2 ssh_by_number --list extra

# --- invalid numbers -------------------------------------------------------

assert_status 'text instead of a number' 2 ssh_by_number abc
assert_status 'zero is not a target number' 2 ssh_by_number 0
assert_status 'negative number' 2 ssh_by_number -3
assert_status 'number out of range' 1 ssh_by_number 99

# --- resolution ------------------------------------------------------------

# The order of the numbers follows the grouping of known-hosts.
overview=$(ssh_known_hosts --lines)
assert_contains 'the aliased target is listed' "$overview" 'aliased'

nr_of() {
    local wanted=$1 gid
    for ((gid = 0; gid < __kh_group_count; gid++)); do
        if [[ ${__kh_group_alias[$gid]} == "$wanted" ||
              ${__kh_group_target[$gid]} == "$wanted" ]]; then
            printf '%d\n' "$((gid + 1))"
            return 0
        fi
    done
    return 1
}

sshp_call=''
ssh_by_number "$(nr_of aliased)"
assert_equal 'an alias is connected through the alias' 'aliased' "$sshp_call"

sshp_call=''
ssh_by_number "$(nr_of aliased)" -v
assert_equal 'options are inserted before the destination' '-v aliased' "$sshp_call"

sshp_call=''
ssh_by_number "$(nr_of '[ported.example.com]:2222')"
assert_equal 'a port target becomes -p plus host' \
    '-p 2222 ported.example.com' "$sshp_call"

sshp_call=''
assert_status 'a marker entry is not connectable' 1 ssh_by_number "$(nr_of '@cert-authority *.example.net')"
assert_equal 'no connection attempt for a marker entry' '' "$sshp_call"

sshp_call=''
assert_status 'a hashed entry is not connectable' 1 ssh_by_number "$(nr_of '[hashed hostname]')"
assert_equal 'no connection attempt for a hashed entry' '' "$sshp_call"

# --- a non-default config is passed on ------------------------------------

cp "$HOME/.ssh/config" "$HOME/.ssh/config.other"
sshp_call=''
SSH_CONFIG_FILE="$HOME/.ssh/config.other" ssh_by_number 1 >/dev/null 2>&1
assert_contains 'a non-default config is passed as -F' "$sshp_call" "-F $HOME/.ssh/config.other"

# --- sshp as an alias ------------------------------------------------------

unset -f sshp
alias_args=''
sshp_target() { alias_args="$*"; }
shopt -s expand_aliases
alias sshp='sshp_target'
sshp_call=''
ssh_by_number "$(nr_of aliased)" 'with space'
assert_equal 'the alias branch keeps arguments intact' 'with space aliased' "$alias_args"
unalias sshp

pass 'help, list, invalid numbers, alias and raw targets, ports, markers, -F pass-through'
