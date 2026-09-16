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
| `known-hosts --clean` after the merge | Passed |
| History writing and deduplication | Passed |
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

### 11. `known-hosts --clean` after the merge

`bashrc.d/lib/known-hosts-clean.sh` and its completion file were removed and the
implementation moved into `bashrc.d/lib/known-hosts.sh` behind the `--clean`
option. Checked with stubbed `ssh`, `ssh-keygen` and `ssh-keyscan` binaries on a
throwaway home directory holding one reachable host, one unreachable host, a
hashed entry and matching config aliases.

| Check | Result |
|---|---|
| `known-hosts --help` shows the merged usage | Passed |
| `known-hosts --clean` dry run: reachable kept, unreachable and its alias reported, hashed skipped, no file written | Passed |
| `known-hosts --clean --apply`: both files rewritten, both backups created, caches invalidated | Passed |
| `known-hosts --apply` without `--clean` returns `2` | Passed |
| `known-hosts --clean --lines` returns `2` | Passed |
| `known-hosts-clean` alias and completion gone, `known-hosts` completion still registered | Passed |
| `bash-commands --check` lists no stale row | Passed |
| `bash tests/known-hosts.sh` still passes unchanged | Passed |

Result: passed.

### 12. History writing and deduplication

Checked in throwaway home directories with `bash --rcfile ... -i`.

**Writing.** With `history -a` in `PROMPT_COMMAND`, every command appears in
`~/.bash_history` immediately, without the shell having exited. Without it the
file stayed at the state of the last `exit`, which is the failure mode a Windows
reboot produces.

**`history -a` vs. `history -n`.** A foreign entry was appended to the file
mid-session to emulate a second terminal.

| `PROMPT_COMMAND` | History list | File |
|---|---|---|
| `history -a; history -n` | foreign entry missing, own command doubled | correct |
| `history -n; history -a` | correct | foreign entry doubled |
| `history -a; history -c; history -r` | correct | correct |

The first ordering is the one commonly copied from the web and is unsafe; the
configuration ships plain `history -a` and leaves cross-terminal sync off.

**Deduplication.** Session with `ll`, `git push`, `ll`, `echo x`, `git push`.
The file directly afterwards, without restarting a shell:

```
ll
echo x
git push
```

Every command exactly once, at the position of its most recent use. Repeats
typed back to back, bare `Enter` on an empty line, and a multi-line `for` block
were checked as well: the block stays a single entry, nothing is lost, and the
following session added no duplicates. A file with entries lacking a `#<epoch>`
line — as produced by pasting a script into the terminal — was deduplicated
without corrupting the remaining timestamps.

Result: passed.

## Still to be checked manually

The following checks can only be carried out in the actual environment:

1. Installation in Git Bash on Windows.
2. Interaction with the really installed version of `bash-git-prompt`.
3. Connection to an actual target server through a gateway or jump host.
4. Rendering of colours and Unicode characters in the terminal in use.
5. Behaviour with password-based SSH authentication.
6. Availability of the GNU `ls` options used on every target server.
8. History persistence across a real Windows reboot, and the runtime cost of
   `history_dedupe` on a grown `~/.bash_history` under Git Bash.

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
