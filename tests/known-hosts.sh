#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source bashrc.d/ssh-tools.sh
SSH_KNOWN_HOSTS_FILE=tests/known_hosts.fixture
calls=0
ssh-keygen() {
    calls=$((calls + 1))
    [[ $* == '-l -E sha256 -f tests/known_hosts.fixture' ]]
}
ssh_known_hosts >/dev/null
[[ $calls == 0 ]]
ssh_known_hosts SERVER >/dev/null
[[ $calls == 0 ]]
ssh_known_hosts --fingerprints
[[ $calls == 1 ]]
output=$(ssh_known_hosts SERVER)
[[ $output == *server.example.com* && $output != *cert-authority* ]]
output=$(ssh_known_hosts)
[[ $output == *'[gehashter Hostname]'* && $output == *cert-authority* ]]
if ssh_known_hosts --fingerprints server 2>/dev/null; then exit 1; fi
printf 'PASS: Standard/Filter 0 Prozesse, Fingerabdruecke 1 Aufruf; Filter und Hashanzeige.\n'
