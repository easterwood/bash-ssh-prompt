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
| `HISTFILE` | `~/.bash_history`, set explicitly |
| `HISTSIZE` | `1000000` |
| `HISTFILESIZE` | `200000` |
| `HISTTIMEFORMAT` | `'%F %T '` |
| `HISTCONTROL` | `erasedups` |
| `shopt histappend` | enabled |
| `shopt cmdhist` | enabled |

`HISTFILE` is set by hand rather than left to the default, because `HOME` is not
reliably the same directory in every Git Bash, WSL or scheduled-task context on
Windows. `cmdhist` keeps a multi-line command as a single entry, which also
makes pasted blocks land in the history as one item instead of one item per
line.

### Writing after every command

Bash saves its history only when the shell exits cleanly. A Windows reboot, a
terminal window that is closed rather than exited, or a crashed session kills
the process without that, and everything typed since the shell started is gone —
the file still holds the state of the last `exit`.

`__history_append` therefore runs `history -a` from `PROMPT_COMMAND`, so the
file is never more than one command behind:

```
history -a    history list of this shell  ->  ~/.bash_history   (append new entries)
history -n    ~/.bash_history  ->  history list of this shell   (read new lines)
```

`history -n` is deliberately **not** used. It would make commands from other
open terminals visible here, but the two directions do not combine cleanly:

- `history -a; history -n` moves the read marker past the shell's own write, so
  entries appended by another terminal in the meantime are skipped, while the
  shell's own last command is read back and appears twice in the list.
- `history -n; history -a` gets the list right but writes the foreign entry back
  to the file, which then holds it twice.
- Only `history -a; history -c; history -r` is correct in both places, and it
  re-reads the whole file at every prompt.

Cross-terminal sync is therefore left off. Each shell keeps its own arrow-up
history during the session; the sessions are merged at the next shell start.

### Deduplication — `history_dedupe`

`HISTCONTROL=erasedups` removes every earlier occurrence of a command from the
history list before the new one is stored, so a repeated command ends up exactly
once, at the end. That applies to the **history list of the running shell only**,
never to the file: `history -a` has already written the earlier occurrence, and
entries read back from the file at the next start are not filtered by
`HISTCONTROL` at all.

`history_dedupe` closes that gap by rewriting the history file so every command
appears exactly once, at the position of its most recent use and with that use's
timestamp. It parses records of `#<epoch>` plus command lines, so multi-line
entries stay intact and entries without a timestamp line — pasted blocks, files
written by an older configuration — are preserved. The new file is built via
`mktemp`, gets the permissions of the original, and replaces it with `mv -f`; if
anything fails the original is left untouched.

It runs in two places:

1. **At shell start.** Bash reads the history file only after the startup files
   have run, so cleaning it up in `history.sh` means the shell comes up with the
   deduplicated list. No `history -c` / `history -r` is needed.
2. **On a repeat, during the session.** `HISTCMD` does not advance when
   `erasedups` drops an entry, because the list does not grow. Comparing it with
   `__history_previous_histcmd` is a free duplicate detector — no subshell, no
   file access — and the rewrite is triggered only when a repeat actually
   happened, not at every prompt.

Set `HISTORY_DEDUPE_LIVE=0` (in `local.sh`, or directly in `history.sh`) to skip
step 2 on very large history files; the file is then cleaned only at shell start.

The function is callable by hand and takes an optional file argument:

```bash
history_dedupe                        # ~/.bash_history
history_dedupe ~/.bash_history.old    # any other history file
```

### Interaction with the command timer

`HISTTIMEFORMAT` is also what makes the timer's `history 1` lookup interesting:
`__cmd_timer_debug` overrides it to empty for its own internal call, so the
timestamp never ends up in `__cmd_last_command`.

## Gruvbox Rainbow prompt — `bashrc.d/prompt-gruvbox.sh`

An alternative to `prompt-local.sh` that reproduces the look of starship's
[Gruvbox Rainbow preset](https://starship.rs/presets/gruvbox-rainbow) in pure
Bash. It replaces `bash-git-prompt` rather than theming it, and reuses the
timer from `prompt-core.sh` unchanged. Which of the two is active is decided by
a single `source` line in `bashrc.sh`.

### Segments

Colours come from the Gruvbox dark palette as 24-bit escapes, separated by the
powerline glyphs `U+E0B6`, `U+E0B0` and `U+E0B4`. Left to right:

| Segment | Colour | Shown when |
|---|---|---|
| OS icon, user | orange | always |
| Working directory | yellow | always |
| Branch and Git status | aqua | `.git` exists in `$PWD` or an ancestor |
| Java, Maven, Node, Python version | blue | the matching project marker is found |
| Docker context | grey | a context outside `PROMPT_GRUVBOX_DOCKER_HIDE` is selected |
| Exit code, duration, clock | dark grey | on a failure, a slow command, or always for the clock |

The second line carries only the input symbol: green `❯`, red `❯` after a
failure, red `#` for root.

Git markers are `=n` conflicts, `+n` staged, `!n` unstaged, `?n` untracked,
`*n` stashes, `⇡n` ahead, `⇣n` behind.

### Cost per prompt

The same rule as everywhere else applies: a fork costs 15-25 ms under MSYS2.

| Situation | Forks |
|---|---|
| Outside a repository | 0 |
| Inside a repository | 1 (`git status --porcelain=v2 --branch --show-stash`) |
| A toolchain that has actually changed | 1 extra, and only then |

The Git call is guarded by a fork-free ancestor walk for `.git`, so a plain
directory never pays for a `git status` that only fails. `branch`, upstream
divergence, stash count and all file states come out of that one call and are
parsed by the shell.

### Freshness

What gets cached is decided by what a refresh would cost, not by the lifetime
of the shell.

The **Java version** is derived from `JAVA_HOME`, or from a JDK path in
`$PATH`, on every single prompt — that is a regular expression over a string
the shell already holds, so it costs nothing and a JDK switch is visible in the
next prompt. Only when neither path carries a version number does `java
-version` have to start a JVM, and that one result is cached against
`JAVA_HOME` and `PATH`; changing either discards it.

The **project version** is read fresh from `pom.xml` on every prompt, so an
edit shows up immediately. A builtin redirection is not a fork, and the loop
stops at the first element that can only follow the version (`<properties>`,
`<modules>`, `<dependencyManagement>`, `<dependencies>`, `<build>`,
`<profiles>`), which puts a normal pom at roughly 0.05 ms — about a fortieth of
one fork under MSYS2. `PROMPT_GRUVBOX_POM_MAX_LINES` bounds the one bad case, a
pom carrying thousands of lines of licence header ahead of its version element.

**Node** and **Python** still cost a fork to interrogate, so they stay cached —
but against `PATH` and `VIRTUAL_ENV`, which is exactly what nvm, fnm, volta and
`activate` rewrite. Switching a Node version re-detects on the next prompt.

The **Docker context** is read from `$DOCKER_CONTEXT`, `$DOCKER_HOST` or
`config.json` once per shell. This is the one value that still needs a new
shell after `docker context use`; drop the `__gb_docker_cache` guard in
`__gb_docker_context` if that matters more than the file read.

`config.json` is looked for under `$DOCKER_CONFIG`, then `$HOME/.docker`, then
`%USERPROFILE%\.docker` with the separators converted — Git Bash does not
guarantee that `$HOME` and `%USERPROFILE%` agree, and Docker Desktop writes
into the latter.

`PROMPT_GRUVBOX_DOCKER_HIDE` suppresses the contexts that only ever mean "the
one local engine". A stock Docker Desktop for Windows reports `desktop-linux`
on every prompt forever, which is a badge without information, so the segment
stays out of the way until the CLI actually points somewhere else. Set the
variable to an empty string to always show the context.

### Settings

All of these can be set in `local.sh`:

| Variable | Default | Effect |
|---|---|---|
| `PROMPT_GRUVBOX_MIN_DURATION_US` | `100000` | Show the duration from this many microseconds on |
| `PROMPT_GRUVBOX_GIT` | `1` | `0` drops the Git segment, and with it the only per-prompt fork |
| `PROMPT_GRUVBOX_POM_MAX_LINES` | `500` | Give up on `pom.xml` after this many lines |
| `PROMPT_GRUVBOX_DOCKER_HIDE` | `default desktop-linux desktop-windows` | Docker contexts that do not earn a segment |
| `PROMPT_GRUVBOX_POWERLINE` | `1` | `0` falls back to ASCII separators without a Nerd Font |
| `PROMPT_GRUVBOX_TIME_ON_INPUT_LINE` | `0` | `1` puts the clock in front of `❯`, as the old Custom theme did |
| `PROMPT_DIRTRIM` | `3` | Path components kept by Bash before truncating |

### Requirements

A Nerd Font in the terminal and a true-colour terminal — Windows Terminal and
mintty both qualify. `LANG` has to name a UTF-8 locale, because the glyphs are
written as `$'\uXXXX'` and Bash converts those using the current locale.

### Remote shells

Unaffected. `prompt.sh` stays the prompt that `sshp` pushes to remote hosts; it
has no dependency on this module and assumes nothing about the remote font.
