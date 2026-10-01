# Test report

## Summary

The modular Bash configuration was verified locally in an isolated Linux test
environment. All locally executable automated checks passed.

Reproducible part: `bash tests/run-all.sh` — 20 scripts, 710 checks, all passing.
CI is configured to run the same suite on the current Ubuntu runner, Git Bash
on Windows, and explicit Bash 4.2.53, 4.4.23, 5.1.16 and 5.3.20 runtimes. A
dedicated Bash 3.2.57 job covers the supported legacy remote prompt. The
remaining sections distinguish local verification from CI-only compatibility
checks.

| Area | Result |
|---|---|
| Automated suite (`tests/run-all.sh`) | Passed |
| Syntax of all shell files | Passed |
| Modular local loader | Passed |
| Local `bash-git-prompt` integration | Passed with a test double; pinned 2.7.1 real integration is configured in CI |
| Local Starship integration | Config tested locally; pinned 1.26.0 real integration is configured in CI |
| Bash version compatibility | CI matrix: 4.2.53, 4.4.23, 5.1.16, 5.3.20; remote fallback separately on 3.2.57 |
| Git Bash compatibility | Full suite and syntax gate configured on `windows-latest` |
| Remote prompt and `ll` | Passed |
| Installation and backup of `.bashrc` | Passed |
| Multi-file sync | Passed (SSH simulated) |
| Per-connection change detection | Passed |
| `known-hosts` overview and filter | Passed |
| `known-hosts --clean` after the merge | Passed |
| History writing and deduplication | Passed |
| ZIP integrity | Passed |

## Test environment

| Component | Version |
|---|---|
| Operating system | Linux, x86-64 |
| Bash | GNU Bash 5.2.37 |
| GNU coreutils (`ls`) | 9.7 |
| AWK | mawk 1.3.4 (20250131) |
| ZIP | Info-ZIP 3.0 |

Git Bash on Windows, the old Bash containers and the actual target servers
were not available in this local execution environment. They are represented by
CI jobs where applicable; real SSH targets remain manual-only.

## Automated suite

```bash
bash tests/run-all.sh       # everything
bash tests/history.sh       # a single script
```

`run-all.sh` runs every `*.sh` in `tests/` except itself and `lib.sh`, prints one
line per script, and returns `1` if any of them failed.

| Script | Checks | Covers |
|---|---|---|
| `tests/bashrc-integration.sh` | 4 | Full `bashrc.sh` composition: prompt hooks survive all backends and source-time settings load before `history.sh` |
| `tests/commands.sh` | 26 | `bash-commands`: listing, `--details`, the `--check` self-test including a deliberately stale row, filter, rejected combinations |
| `tests/completion.sh` | 35 | Completion lists derived from the shared SSH inventory, invalidation after a config edit, `ssh`/`sshp` destinations including `user@`, every per-command completion, and the shared resolver registration |
| `tests/history.sh` | 26 | `history_dedupe`, serialized concurrent writers, stale-lock recovery, timestamped/multi-line/timestamp-less files, the shipped `HISTORY_DEDUPE_LIVE=0` default, live rewrite, and the `prompt-core.sh` guard |
| `tests/install.sh` | 30 | The generated loader, the backup, `printf %q` quoting of a path with spaces, the whole-tree `bash -n` gate including `lib/`, `completions/` and `local.sh`, and that `bashrc.sh` stays inert in a non-interactive shell |
| `tests/known-hosts-clean.sh` | 39 | `known-hosts --clean`: dry run, `--apply` with backups, rejected combinations, the removed `known-hosts-clean` alias, and the completion |
| `tests/known-hosts.sh` | 15 | The `known_hosts` parser, filter/process behaviour, and automatic invalidation after an SSH config edit |
| `tests/listing.sh` | 18 | The `ll` header, the dropped `ls` summary line, hidden files, names with spaces, option pass-through, and propagation of the underlying `ls` exit status |
| `tests/prompt-core.sh` | 40 | Central string/array `PROMPT_COMMAND` composition plus the clock, duration formatting, exit-code capture, shared text helpers, and window-title escaping |
| `tests/prompt-gruvbox.sh` | 62 | The pure-Bash Gruvbox prompt: palette, segment engine, Git segment, toolchain detection and the second powerline line |
| `tests/prompt-local.sh` | 19 | `prompt_callback`: order of duration, last command and exit code, quoting, the two repetition knobs, and the four performance switches |
| `tests/remote-prompt.sh` | 31 | `prompt.sh`: the pre-4.2 fallback builder and the remote Gruvbox wiring, including deliberate removal of inherited server `PROMPT_COMMAND` hooks |
| `tests/prompt-selection.sh` | 9 | The `local.sh` backend selector: Starship, `bash-git-prompt`, Gruvbox, and the fallback warnings |
| `tests/ssh-by-number.sh` | 19 | `ssh-nr`: help, `--list`, invalid and out-of-range numbers, alias versus raw target, `[host]:port`, markers, `-F` pass-through, both `sshp` call branches |
| `tests/ssh-config.sh` | 57 | The shared `ssh_config` line tokenizer, scanner behaviour, the shared config/known_hosts inventory, Include-glob invalidation, cached `ssh -G`, and removed legacy resolver completions |
| `tests/ssh-resolve-backends.sh` | 69 | Every DNS backend of both resolvers against stubbed `getent`, `dig`, `host`, `nslookup` and `powershell.exe`: each tool's output format, the fallback order, the timeout wrapper, positive and negative caching, and the two token extractors |
| `tests/ssh-resolve-table.sh` | 34 | `__ssh_resolve_table` against a stubbed `ssh -G` and pre-seeded DNS caches: columns, merged references, bracketed IPv6, skipped hashed entries, filter, empty results, cache invalidation, and the full config line syntax reaching the CONFIG column |
| `tests/ssh-resolve.sh` | 56 | Strict IPv4/IPv6 predicates including compression, scoped addresses and embedded IPv4, plus help, argument/timeout validation and resolver source-time guards |
| `tests/sshp.sh` | 98 | The `sshp` argument parser, configurable/version-gated `WarnWeakCrypto`, `SSHP_SYNC_STATUS`, terminal-only spinner phases, silent cache hits, effective `ssh -G` cache identity, per-port/config state separation, equivalent-alias cache sharing, staged remote publication/rollback safety, the remote syntax gate over every synced file, `--force`, `--`, remote-command rejection, and missing sync files |
| `tests/starship-config.sh` | 23 | `starship.toml`: the removed helper script, the constant bg1 field on line one, the rounded caps on line two, and the palette matching `prompt-gruvbox.sh` |

The network-free suite is complemented in CI by three integration checks:

- `tests/integration/bash-git-prompt.sh` runs against pinned upstream 2.7.1 and
  performs a real prompt render in a temporary Git repository.
- `tests/integration/starship.sh` runs against pinned Starship 1.26.0, renders
  the versioned TOML and loads the complete Starship backend.
- `tests/integration/legacy-bash.sh` runs under Bash 3.2.57 and exercises the
  actual pre-4.2 branch in `prompt.sh`.

The full regular suite additionally runs under Bash 4.2.53, 4.4.23, 5.1.16
and 5.3.20, and under Git Bash on `windows-latest`.

## Checks performed

### 1. Bash syntax

The following files were checked individually with `bash -n`:

The gate now covers every `*.sh` and `*.bash` in the tree, including
`bashrc.d/lib/*.sh` and `bashrc.d/completions/*.bash`, which `install.sh` skips:

```bash
find . -name '*.sh' -o -name '*.bash' | xargs -n1 bash -n
```

Result: no syntax errors. The same command runs as the `syntax` job in
`.github/workflows/ci.yml`.

`bashrc.d/lib/ssh-command.sh` was removed. It had not been sourced by
`ssh-tools.sh` for some time — `docs/architecture.md` already described it as
gone — so it was dead code that `bash -n` kept validating.
`bashrc.snippet.sh` was removed for the same reason: it documented a
`~/.config/bash/ssh-prompt/` layout and a `PROMPT_SYNC_FILE` variable that no
code reads. Its one genuinely useful part, the optional `ssh()` wrapper, now
lives in `docs/ssh-sync.md`.

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

- `prompt-core.sh`, `listing.sh` and `prompt-gruvbox.sh` are found relative to
  `prompt.sh`;
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
- cache identity follows effective SSH host/user/port and proxy settings rather
  than the literal destination string;
- different ports and configs resolving one alias to different hosts create
  independent state, while equivalent aliases can share state;
- `prompt.sh`, `listing.sh`, `prompt-core.sh` and `prompt-gruvbox.sh` are
  transferred;
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

Reproducible regression test: `bash tests/known-hosts.sh` (passed, 15 checks).
The `ssh-keygen` stub counts calls and checks arguments; synthetic parser data
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
option.

> Later update: the merged file had grown to 1148 lines across four concerns,
> so the `--clean` implementation moved back into
> `bashrc.d/lib/known-hosts-clean.sh` — see section 13. The user-visible
> interface is unchanged: `--clean` is still an option of `known-hosts`, the
> `known-hosts-clean` alias is still gone, and the 39 checks below still pass.

Reproducible regression test: `bash tests/known-hosts-clean.sh` (passed, 39
checks). The fixture is a throwaway home directory with one reachable host, one
unreachable host, a hashed entry and matching config aliases; `ssh`,
`ssh-keygen` and `ssh-keyscan` are stubs.

| Check | Result |
|---|---|
| `known-hosts --help` shows the merged usage, including the keyscan timeout | Passed |
| Dry run: reachable kept, unreachable and its alias reported, hashed skipped | Passed |
| Dry run writes neither `known_hosts` nor the config | Passed |
| `--apply`: both files rewritten, both backups created, the live host survives | Passed |
| The overview after `--apply` reflects the new state, so the caches were invalidated | Passed |
| `--apply` without `--clean`, and `--clean` with `--lines`, `--refresh`, `--fingerprints` or a filter, all return `2` | Passed |
| `known-hosts-clean` alias, function and completion function are gone | Passed |
| Completion offers `--clean`, then only `--apply`/`--help` and no host names | Passed |

`bash-commands --check` lists no stale row, and `bash tests/known-hosts.sh`
passes unchanged.

Result: passed.

### 12. History writing and deduplication

Reproducible regression test: `bash tests/history.sh` (passed, 26 checks). The
file-level checks call `history_dedupe` directly; the behavioural checks start
`bash --rcfile ... -i` in a throwaway home directory, because `history -a` and
`erasedups` only do anything in an interactive shell.

**Writing.** With `history -a` in `PROMPT_COMMAND`, every command appears in
`~/.bash_history` immediately, without the shell having exited. Without it the
file stayed at the state of the last `exit`, which is the failure mode a Windows
reboot produces.

**Concurrency.** `history -a` and `history_dedupe` use the same noclobber lock
file. The regression test holds that lock in one shell and verifies that a
second shell cannot append until it is released; it also verifies recovery from
a stale lock owned by a dead PID. This prevents an append from landing on the
old inode while another shell replaces the history file.

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

### 13. Second pass on duplication

Three code paths existed more than once and were merged. Each change was
verified against the suite, and the resolver merge additionally against the
output of the previous implementation.

**The two resolvers.** `ssh_resolve_ips` and `ssh_resolve_hosts` were 245 and
246 lines, around 80 % identical once the identifiers were normalised: the
three local accumulators, the config scan, the `known_hosts` scan, the filter
loop and both output blocks were character-for-character copies. The shared
part is now `__ssh_resolve_table` in `bashrc.d/lib/ssh-resolve.sh`; each
command supplies an extractor, a lookup and its column headers.

Equivalence was checked by running both implementations against the same
fixture — a config with IP literals, a wildcard `Host`, a `%h` token and an
alias, plus a `known_hosts` with a comment, a blank line, a bracketed IPv6
target with a port, a hashed entry, a `@cert-authority` marker and a
multi-name line — across five invocations, filtered and unfiltered, with
pre-seeded DNS caches. **The output was byte-identical.**

| File | Before | After |
|---|---|---|
| `lib/ssh-resolve.sh` | — | 320 |
| `lib/ssh-resolve-ips.sh` | 438 | 171 |
| `lib/ssh-resolve-hosts.sh` | 443 | 217 |

`tests/ssh-resolve-table.sh` (27 checks) was added, because the shared body had
no coverage at all: `tests/ssh-resolve.sh` only exercises paths that return
before any DNS lookup.

**The `known_hosts` parser and the `ssh -G` call.** Both existed at seven
sites. They are now `__kh_parse_known_line`, `__kh_split_host_port`,
`__kh_ssh_config_dump`, `__kh_ssh_config_field` and `__kh_lookup_key` in
`lib/ssh-config.sh`. Two defects surfaced while migrating:

- `__kh_refresh` did not strip `\r`, while the resolvers did, so a CRLF
  `known_hosts` behaved differently depending on the command. Now uniform.
- In `__kh_clean_run` an unparsable non-comment line fell through to the
  `CHECK` branch and was effectively dropped by `--apply`. It is now written
  back unchanged and reported as `SKIP unparsable line`.

**The resolver completions.** `completions/ssh-resolve-ips.bash` and
`completions/ssh-resolve-hosts.bash` were byte-identical apart from the
function name. One `_ssh_resolve_completion` in `completions/ssh-resolve.bash`
is registered for both commands. The unquoted `COMPREPLY=( $(compgen ...) )`
assignment was replaced by the loop form used elsewhere in the tree.

### 14. Structure and error paths

- `lib/known-hosts.sh` was split at 1148 lines into `known-hosts.sh` (482:
  cache, grouping model, display) and `known-hosts-clean.sh` (646). Only
  `ssh_known_hosts` reaches across the boundary.
- `__kh_clean_run` runs in a subshell with one `trap ... EXIT HUP INT TERM`,
  replacing eight hand-placed `rm -f` calls. Because a subshell cannot
  invalidate the caller's caches, `ssh_known_hosts` drops them after a
  successful `--apply`.
- Every module that needs another one now says so at source time with a
  `declare -F ... || return 1` guard: `history.sh`, both prompt backends,
  `ssh-by-number.sh`, both resolvers and both `known-hosts` files. Two tests
  had been relying on the previously silent load order and were corrected.
- The Gruvbox palette still exists twice, as RGB in `prompt-gruvbox.sh` and as
  hex in `starship.toml`. `tests/starship-config.sh` now converts and compares
  them, so drift fails the build.

Result: passed.

### 15. The resolver DNS backends

The backend chain was the last part of the resolvers with no coverage at
all. `tests/ssh-resolve.sh` returns before any lookup and
`tests/ssh-resolve-table.sh` pre-seeds the caches, so roughly 170 lines of
`awk` over five tools' output formats, in two directions, were never
executed by a test — while being the code most exposed to platform
differences, since `getent`, `dig`, `host`, `nslookup` and PowerShell word
their answers differently on every target the project supports.

`tests/ssh-resolve-backends.sh` stubs all five tools. Each stub records its
invocation and answers from a fixture file, so a scenario is set up by
writing fixtures rather than by rewriting stubs, and the fallback order can
be asserted instead of only the final result. Covered per direction: each
tool's own output format, the order in which they are tried, the complete
failure when none of them answers, the `timeout` wrapper cutting off a
hanging backend, positive and negative caching including the `\x1e`
sentinel, cache invalidation, and the deduplication and IPv4-before-IPv6
ordering of the forward lookup. The test opens no network connection.

Four deliberate mutations were used to confirm the test actually binds:
removing the `Name:` branch of the reverse `nslookup` parser, dropping the
IPv4-first ordering, removing the `tr -d '\r'` behind the PowerShell
backend, and no longer storing the negative sentinel. Each one failed the
suite, with a message naming the behaviour that broke.

Result: passed.

### 16. The `ssh_config` line syntax

The tokenizer that turns one `ssh_config` line into a keyword and its arguments
existed twice: in `__kh_scan_file` and, character for character with the
identifiers renamed, inside `__ssh_resolve_table`. Both copies strip `\r` from
CRLF files, cut `#` comments, normalise the `Keyword=value` form to
`Keyword value`, lowercase the keyword and remove one layer of quotes per
token. That is the same class of split-brain defect section 13 removed for the
`known_hosts` parser, where a missing `\r` strip on one side made a CRLF file
behave differently depending on which command read it.

Both now call `__kh_parse_config_line` in `lib/ssh-config.sh`, next to
`__kh_parse_known_line`. It reports the lowercased keyword in
`__kh_config_keyword` and the keyword plus its unquoted arguments in
`__kh_config_words`, which callers read as `[@]:1` — the same expansion the
scanner already used, so nothing changes for the Bash 4.2 target.

| File | Before | After |
|---|---|---|
| `lib/ssh-config.sh` | 316 | 329 |
| `lib/ssh-resolve.sh` | 261 | 253 |

Code lines, comments excluded. The change is deliberately not a line-count win:
the shared function costs more than the nine inlined lines it replaces on each
side, because it has to publish its result. What it buys is that the line
syntax has exactly one definition.

No behaviour change was intended and none was observed: the whole suite passed
unchanged before new checks were added. Coverage was then pinned down from both
sides — 20 new checks in `tests/ssh-config.sh` for the tokenizer itself (blank,
comment-only and inline-comment lines, keyword case, `Keyword=value` with a
second `=` inside the value, quoted values, CRLF endings, collapsed
whitespace, a keyword without a value) and 7 in `tests/ssh-resolve-table.sh`
proving the same syntax reaches the resolver's CONFIG column.

Three mutations of the shared tokenizer confirm both consumers really go
through it: dropping the `\r` strip, dropping the unquoting, and dropping the
`=` normalisation each fail `tests/ssh-config.sh` **and**
`tests/ssh-resolve-table.sh`.

Result: passed.

### 17. One definition per list

Two lists were maintained by hand in more than one place.

**`sync_files`.** The set of files `sshp` pushes was declared as an array in
`ssh-prompt.sh` and then repeated as four hard-coded `bash -n` lines inside the
remote heredoc. Adding a file meant editing both, and forgetting the second
edit meant the new file reached the destination without ever being
syntax-checked there — silently, because nothing fails when a check is simply
absent. The local side now prepends `sync_files='…'` to the remote script and
the remote pass loops over it. The names are validated against
`[[:alnum:]./_-]` before they are embedded, so the single-quoted assignment is
safe by construction rather than by convention. `sshp-sync-format` is
deliberately **not** bumped: neither the payload nor the remote layout changed,
so no host needs to re-sync.

**The installer's syntax gate.** `install.sh` ran `bash -n` over a
hand-maintained list of twelve files that covered neither `bashrc.d/lib/*.sh`
nor `bashrc.d/completions/*.bash` — about half the tree, and the half most
likely to be edited. This was limitation 3 in `docs/architecture.md`; it is now
gone from that list. The installer runs the same `find` expression the CI
syntax job uses, reports every offender in one run instead of stopping at the
first, and aborts with an explicit message before touching `~/.bashrc`. An
untracked `local.sh` is included on purpose: `bashrc.sh` sources it, so a
syntax error there breaks the shell just as surely.

Coverage: `tests/install.sh` grew from 21 to 30 checks — a broken
`bashrc.d/lib/known-hosts.sh`, `bashrc.d/completions/ssh.bash` and `local.sh`
each abort the installation, two broken files are both named in one run, the
abort message is asserted, and a clean checkout still passes the wider gate.
`tests/sshp.sh` grew from 86 to 98: each of the four synced files, rejected in
turn by the fake remote `bash`, has to abort the sync, which proves the remote
loop really covers all of them and not just the first.

Four mutations confirm it: reducing the remote loop to `prompt.sh`, dropping
the prepended list, restoring a subset-only installer gate, and making the
installer stop at the first error — each fails the matching test script.

Result: passed. 20 scripts, 710 checks.

## Still to be checked manually

The following checks can only be carried out in the actual environment:

1. Interaction with a locally installed `bash-git-prompt` if it differs from
   the pinned 2.7.1 CI version.
2. Connection to an actual target server through a gateway or jump host.
3. Rendering of colours and Unicode characters in the terminal in use.
4. Behaviour with password-based SSH authentication.
5. Availability of the GNU `ls` options used on every target server.
6. History persistence across a real Windows reboot, and the runtime cost of
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
