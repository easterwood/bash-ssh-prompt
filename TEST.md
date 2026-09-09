# Test report

## Summary

The modular Bash configuration was verified on 8 September 2026 in an isolated
Linux test environment. All automated checks passed.

| Area | Result |
|---|---|
| Syntax of all shell files | Passed |
| Modular local loader | Passed |
| Local `bash-git-prompt` integration | Passed (with a test double) |
| Remote prompt and `ll` | Passed |
| Installation and backup of `.bashrc` | Passed |
| Multi-file sync | Passed (SSH simulated) |
| Per-target change detection | Passed |
| `known-hosts` overview and filter | Passed |
| ZIP integrity | Passed |

## Test environment

| Component | Version |
|---|---|
| Operating system | Linux, x86-64 |
| Bash | GNU Bash 5.2.21 |
| GNU coreutils (`ls`) | 9.4 |
| AWK | mawk 1.3.4 (2024-01-23) |
| ZIP | Info-ZIP 3.0 |

Git Bash on Windows and the actual target servers were not part of the
executable test environment.

## Checks performed

### 1. Bash syntax

The following files were checked individually with `bash -n`:

- `bashrc.sh`
- `prompt.sh`
- `ssh-prompt.sh`
- `.git-prompt-colors.sh`
- `install.sh`
- `bashrc.d/environment.sh`
- `bashrc.d/history.sh`
- `bashrc.d/listing.sh`
- `bashrc.d/ssh-tools.sh`
- `bashrc.d/prompt-core.sh`
- `bashrc.d/prompt-local.sh`

Result: no syntax errors.

### 2. Removal of duplicates

The shared definitions were searched for across the whole package.

| Definition | Only location |
|---|---|
| `__cmd_timer_now_us` and the other timer functions | `bashrc.d/prompt-core.sh` |
| `ll` | `bashrc.d/listing.sh` |
| `TIME_STYLE` | `bashrc.d/listing.sh` |
| Local git prompt integration | `bashrc.d/prompt-local.sh` |

The remote prompt sources `listing.sh` and `prompt-core.sh` instead of
duplicating their contents.

### 3. Local configuration

A temporary home directory and a minimal test implementation of
`bash-git-prompt` were created. The installed `.bashrc` was then loaded in an
interactive Bash.

Checked:

- all modules are loaded in the intended order;
- `ll`, the timer, `sshp` and the `ssh` wrapper are defined;
- the `Custom` theme is active;
- `.git-prompt-colors.sh` is loaded from the Git project;
- an optional `local.sh` is not required.

Result: passed.

### 4. Installer

The installer was run against an already existing `.bashrc` in a temporary home
directory.

Checked:

- the previous `.bashrc` is backed up with a timestamp;
- the new `.bashrc` contains nothing but the loader for the Git checkout;
- the generated loader passes the syntax check;
- paths are written in a shell-safe way.

Result: passed.

### 5. Remote prompt

`prompt.sh` was loaded in an interactive Bash with simulated SSH variables.

Checked:

- `prompt-core.sh` and `listing.sh` are found relative to `prompt.sh`;
- the remote prompt builder is installed;
- the shared `ll` function is available;
- `ll` can render a file without errors;
- the welcome block is not repeated, thanks to `SSHP_WELCOME_SHOWN`.

Result: passed.

### 6. `ll` rendering

Checked:

- header row with permissions, link, user, size, date and name columns;
- no group column;
- time format `YYYY-MM-DD HH:MM:SS`;
- human-readable file sizes;
- `root` is rendered in red;
- the current user and other users use different colours.

Result: passed.

### 7. SSH sync

The `ssh` client executable was replaced with a local test double. The remote
script was run in a separate temporary home directory.

Checked:

- the first call creates one sync and one login connection;
- without a local change, the second call creates only the login connection;
- `prompt.sh`, `listing.sh` and `prompt-core.sh` are transferred;
- the loader is written to the remote `.bashrc` exactly once;
- the local sync state is only stored after a successful transfer.

Observed connection count: `2`, then `1`.

Result: passed.

### 8. `ssh` wrapper

| Call | Expected path | Result |
|---|---|---|
| `ssh server` | `sshp server` | Passed |
| `ssh -p 2222 server` | native `ssh` | Passed |
| `ssh server uname -a` | native `ssh` | Passed |
| `command ssh server` | native `ssh` | Passed |

### 9. `known-hosts` overview

Update: the default view and the filter no longer spawn an `ssh-keygen` process.
`--fingerprints` spawns exactly one call for the whole file and returns the
original OpenSSH output.

Reproducible regression test: `bash tests/known-hosts.sh` (passed).
The test double counts calls and checks arguments; synthetic parser data
exercises the filter, markers and the hash display. It is neither a
cryptographic test nor a runtime measurement under Git Bash. The checks below
additionally describe the earlier state with real test keys.

The `known-hosts` function was checked with plaintext, port, marker and hashed
test entries. Plaintext targets can be filtered; hashed hostnames are not
falsely rendered as a readable target name. Key type and SHA256 fingerprint are
derived from the stored key.

Result: passed.

### 10. Package integrity

The ZIP archive was checked in full with `unzip -t`.

Result: no corrupted entries.

## Still to be checked manually

The following checks can only be carried out in the actual environment:

1. Installation in Git Bash on Windows.
2. Interaction with the really installed version of `bash-git-prompt`.
3. Connection to an actual target server through a gateway or jump host.
4. Rendering of colours and Unicode characters in the terminal in use.
5. Behaviour with password-based SSH authentication.
6. Availability of the GNU `ls` options used on every target server.

## Manual acceptance test

```bash
bash -n ~/.bashrc
source ~/.bashrc
ll
ssh SERVER
exit
ssh SERVER
```

On the first SSH call after a local change, two connections are established.
The immediately following unchanged call needs only one.
