# Prompt, timer and listing

Three files carry the shell experience, and two of them are shared between local
and remote shells:

| File | Loaded locally | Synced to remote hosts |
|---|---|---|
| `bashrc.d/prompt-core.sh` | yes | yes |
| `bashrc.d/listing.sh` | yes | yes |
| `bashrc.d/prompt-local.sh` | yes | no |
| `prompt.sh` | no | yes |

The split exists so the timer and `ll` are defined exactly once. `prompt.sh`
sources the two shared files relative to its own directory rather than
duplicating them.

## Command timer — `bashrc.d/prompt-core.sh`

The timer is built from a `DEBUG` trap plus `PROMPT_COMMAND` hooks. Four
functions do the work:

**`__cmd_timer_now_us`** returns the current time in microseconds via `REPLY`.
It prefers `EPOCHREALTIME` (Bash 5.0+, and handles a comma decimal separator
from locales such as `de_DE`), falling back to `date +%s%6N`.

**`__cmd_timer_debug`** runs on the `DEBUG` trap, i.e. just before a command
executes. It ignores the prompt machinery itself (`setLastCommandState`,
`__cmd_timer_stop`, `__remote_prompt_build`, `__cmd_timer_arm`), disarms the
trap so it fires only once per command line, reads the command text from
`history 1` (falling back to `$BASH_COMMAND`), trims it, stores it in
`__cmd_last_command`, updates the window title, and records the start time.

**`__cmd_timer_stop`** captures `$?` into `__cmd_last_exit`, computes
`__cmd_elapsed_us`, and formats `__cmd_duration`:

| Elapsed | Format | Example |
|---|---|---|
| < 1 ms | fixed string | `<1ms` |
| < 1 s | milliseconds, rounded | `247ms` |
| < 1 min | seconds with milliseconds | `3.482s` |
| < 1 h | minutes and seconds | `2m07s` |
| ≥ 1 h | hours, minutes, seconds | `1h04m09s` |

It returns the original exit code, so it is safe as the first entry in
`PROMPT_COMMAND`.

**`__cmd_timer_arm`** re-applies the window title and re-arms the `DEBUG` trap.
It must run **last** in `PROMPT_COMMAND`.

### Window title

`__cmd_set_window_title` emits an `OSC 0` sequence with the format
`<command> — <directory>`. The directory is `~` for `$HOME`, `/` for the root,
otherwise the basename of `$PWD`. Escape, bell, carriage return, newline and tab
characters are stripped or replaced first, so a multi-line command cannot break
out of the title sequence.

## Local prompt — `bashrc.d/prompt-local.sh`

This module wires the timer into `bash-git-prompt` and adds a status segment.

`prompt_callback` is the hook `bash-git-prompt` calls when building the prompt.
It prints:

- on a non-zero exit code: a red `✗ <code>`, plus ` · <duration>` if one was
  measured;
- otherwise, if the command took **100 ms or more**: the duration in green;
- nothing at all for fast, successful commands.

Ordering is handled explicitly, and both the string and the Bash 5.1 array form
of `PROMPT_COMMAND` are supported:

1. `__cmd_timer_stop` is **prepended**, so the exit code and duration are
   captured before `bash-git-prompt` reads them.
2. `bash-git-prompt` is sourced from `~/.bash-git-prompt/gitprompt.sh`, if
   present.
3. `__cmd_timer_arm` is **appended**, so the `DEBUG` trap is the last thing set.

Git prompt settings applied here:

| Variable | Value | Effect |
|---|---|---|
| `GIT_PROMPT_ONLY_IN_REPO` | `0` | The custom prompt is used everywhere, not just in repositories |
| `GIT_PROMPT_THEME` | `Custom` | Selects the bundled theme |
| `GIT_PROMPT_SHOW_UPSTREAM` | `1` | Shows the tracked upstream branch |
| `GIT_PROMPT_THEME_FILE` | `$BASH_CONFIG_ROOT/.git-prompt-colors.sh` | Uses the versioned theme from this repo |

## Git prompt theme

In `.git-prompt-colors.sh`, `override_git_prompt_colors` defines the `Custom`
theme:

- Two lines: information on the first, the input symbol on the second, with the
  time (`\t`) in front of it.
- Path in yellow (`PathShort`), or red for `root`.
- `user@host` in cyan is prefixed **only** when `SSH_CONNECTION` is set, so a
  local shell stays compact.
- Prompt symbol: bold green `❯` for a normal user, bold red `#` for root.
- No leading space, no separate OK/FAIL markers — the status comes from
  `prompt_callback`.

The file ends with `reload_git_prompt_colors "Custom"` so the theme applies
immediately when re-sourced.

## Remote prompt — `prompt.sh`

`prompt.sh` is what `sshp` copies to remote hosts. It returns immediately in
non-interactive shells and has **no** dependency on `bash-git-prompt`, local
files, or Windows paths — that independence is what makes it safe to push to an
arbitrary server.

### Welcome block

On the first interactive shell of a connection it prints a two-line banner:

```
╭─ REMOTE    server.example.com
╰─ USER      alex · IP 10.0.0.7
```

The hostname comes from `hostname -f`, falling back to `hostname` and then `?`.
The IP is the third field of `SSH_CONNECTION` (the server address). The banner
is suppressed on nested shells by the exported guard `SSHP_WELCOME_SHOWN`.

### Prompt layout

`__remote_prompt_build` assembles `PS1` from up to three parts:

```
letzter: git status --short          <- dim, optional
[SSH web01] ~/projects/api  ✗ 1 · 312ms
09:41:07 ❯
```

- **Last-command line** — dim, prefixed `letzter:`. Controlled by
  `SSH_PROMPT_SHOW_COMMAND`; set it to `0` before the prompt is built to hide
  it.
- **`[SSH <host>]`** in cyan, only when `SSH_CONNECTION` is set.
- **Working directory** — `\w`, yellow for a normal user, red for root.
- **Status** — red `✗ <code>` plus duration on failure, or the duration in green
  when a successful command took 100 ms or more.
- **Second line** — the time, then bold green `❯` or bold red `#`.

`PROMPT_COMMAND` is then set to the fixed sequence
`__cmd_timer_stop` → `__remote_prompt_build` → `__cmd_timer_arm`, again in
either array or string form depending on the Bash version. Unlike the local
module this **replaces** any existing `PROMPT_COMMAND`, which is intentional:
the remote shell should look the same regardless of what the server's default
`.bashrc` set up.

## Listing — `bashrc.d/listing.sh`

`ll` wraps GNU `ls` and reformats its output with `awk`:

```bash
ll
ll -R /var/log
ll ~/projects/*.md
```

All arguments are passed straight through to `ls`, which always runs with:

```
-oah --color=always --group-directories-first --time-style='+%Y-%m-%d %H:%M:%S'
```

`-o` means the group column is omitted by design. `TIME_STYLE` is also exported
globally, so a plain `ls -l` uses the same timestamp format.

Output columns, with a dim header row:

| Column | Contents |
|---|---|
| `PERMS` | Permission bits, dim |
| `LINK` | Hard-link count |
| `USER` | Owner — red for `root`, cyan for the current user, magenta for anyone else |
| `SIZE` | Human-readable size, yellow |
| `MODIFIED` | `YYYY-MM-DD HH:MM:SS`, blue |
| `NAME` | Filename, keeping `ls` colours; spaces and `->` link targets survive |

A domain suffix is stripped from the owner name (`alex@corp` → `alex`) before
comparing against the current user, which matters on Windows and AD-joined
hosts. The `total`/`insgesamt` summary line from `ls` is dropped.

`unalias ll` runs first, so the function wins over a distribution-provided
alias.

Because the reformatting is positional (`$1`–`$6` plus `$7…NF` for the name),
`ll` needs GNU `ls`. On a host with BusyBox or BSD `ls` the columns will not
line up.

## History — `bashrc.d/history.sh`

| Setting | Value |
|---|---|
| `HISTSIZE` | `1000000` |
| `HISTFILESIZE` | `20000000` |
| `HISTTIMEFORMAT` | `'%F %T '` |
| `shopt histappend` | enabled |

`HISTTIMEFORMAT` is also what makes the timer's `history 1` lookup interesting:
`__cmd_timer_debug` overrides it to empty for its own internal call, so the
timestamp never ends up in `__cmd_last_command`.
