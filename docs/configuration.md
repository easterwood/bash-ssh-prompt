# Configuration reference

## Environment variables

### Set by the configuration

| Variable | Set in | Value |
|---|---|---|
| `BASH_CONFIG_ROOT` | `bashrc.sh` | Absolute path of the checkout, resolved with `pwd -P`. Exported, so `sshp` and helpers can find their files |
| `TIME_STYLE` | `bashrc.d/listing.sh` | `+%Y-%m-%d %H:%M:%S` — also affects plain `ls -l` |
| `HISTFILE` | `bashrc.d/history.sh` | `~/.bash_history` — set explicitly, because `HOME` differs between Git Bash, WSL and task contexts on Windows |
| `HISTSIZE` | `bashrc.d/history.sh` | `1000000` |
| `HISTFILESIZE` | `bashrc.d/history.sh` | `200000` |
| `HISTTIMEFORMAT` | `bashrc.d/history.sh` | `'%F %T '` |
| `HISTCONTROL` | `bashrc.d/history.sh` | `erasedups` — a repeated command keeps only its most recent occurrence. Append `:ignorespace` to also drop commands typed with a leading space |
| `SSHP_WELCOME_SHOWN` | `prompt.sh` | Exported guard so the remote welcome banner appears once per connection, not in nested shells |
| `JMETER_PATH`, `PATH`, `ANDROID_HOME`, `MAVEN_OPTS` | `bashrc.d/environment.sh` | Machine-specific — see below |
| `GIT_PROMPT_ONLY_IN_REPO`, `GIT_PROMPT_THEME`, `GIT_PROMPT_SHOW_UPSTREAM`, `GIT_PROMPT_THEME_FILE` | `bashrc.d/prompt-local.sh` | `bash-git-prompt` settings |

### Read by the configuration

Set these before sourcing, in `local.sh`, or per command.

| Variable | Default | Read by | Effect |
|---|---|---|---|
| `SSH_KNOWN_HOSTS_FILE` | `~/.ssh/known_hosts` | `known-hosts` (incl. `--clean`), `ssh-nr`, `ssh-resolve-ips`, all completions | Which `known_hosts` file to use |
| `SSH_CONFIG_FILE` | `~/.ssh/config` | same as above | Which SSH config to treat as primary. When it differs from the default, the tools pass `-F` explicitly |
| `SSH_RESOLVE_IP_TIMEOUT` | `3` | `ssh-resolve-ips` | Reverse-DNS timeout in seconds. Must be a positive integer |
| `SSH_RESOLVE_HOST_TIMEOUT` | `3` | `ssh-resolve-hosts` | Forward-DNS timeout in seconds. Must be a positive integer |
| `SSH_KNOWN_HOSTS_CLEAN_TIMEOUT` | `3` | `known-hosts --clean` | `ssh-keyscan` timeout in seconds. Must be a positive integer |
| `SSH_PROMPT_SHOW_COMMAND` | `1` | `prompt.sh` | `0` hides the dim `letzter: <command>` line in the remote prompt |
| `HISTORY_DEDUPE_LIVE` | `1` | `bashrc.d/history.sh` | `0` rewrites the history file only at shell start instead of also right after a repeated command. Useful on very large history files |
| `BASH_PROMPT_BACKEND` | `auto` | `bashrc.sh` | Local prompt: `starship`, `bash-git-prompt`, `gruvbox`, or `auto`. Aliases: `prompt-local`, `git`, `prompt-gruvbox`, `prompt-gruvbox.sh` |
| `STARSHIP_CONFIG` | `<checkout>/starship.toml` | `bashrc.sh` | Optional override for the Starship config path when the Starship backend is selected |

### Internal variables

Not meant to be set by hand, but useful when debugging:

| Variable | Meaning |
|---|---|
| `__cmd_last_exit` | Exit code of the last command |
| `__cmd_last_command` | Text of the last command, used for the prompt line and window title |
| `__cmd_elapsed_us` | Duration of the last command in microseconds |
| `__cmd_duration` | Formatted duration, e.g. `247ms` |
| `__cmd_timer_start_us` | Start timestamp, unset after each measurement |
| `__history_previous_histcmd` | `HISTCMD` as of the previous prompt. It stalls when `erasedups` drops an entry, which is how a repeated command is detected without a subshell |

## Files and directories

### Local

| Path | Written by | Contents |
|---|---|---|
| `~/.bashrc` | `install.sh` | Three-line loader for the checkout |
| `~/.bashrc.before-modular-config.<timestamp>` | `install.sh` | Backup of the previous `~/.bashrc` |
| `~/.cache/sshp/<crc>_<size>.state` | `sshp` | Sync signature, keyed by the destination string (options are not part of the key) |
| `<checkout>/local.sh` | you | Untracked machine-local settings, loaded after the common modules and immediately before the local prompt backend is selected |
| `~/.ssh/known_hosts.bak.<timestamp>` | `known-hosts --clean --apply` | Backup, only when the file actually changes |
| `~/.ssh/config.bak.<timestamp>` | `known-hosts --clean --apply` | Backup, only when the file actually changes |
| `~/.bash-git-prompt/` | you | Optional `bash-git-prompt` checkout |
| `~/.bash_history` | Bash, `history -a`, `history_dedupe` | Written after every command, not only on exit. Rewritten in place when duplicates are removed |
| `~/.bash_history.XXXXXX` | `history_dedupe` | Short-lived temporary file, moved over `~/.bash_history` or deleted |

### Remote (created by `sshp`)

| Path | Contents |
|---|---|
| `~/.cache/ssh-prompt/prompt.sh` | Synced remote prompt |
| `~/.cache/ssh-prompt/bashrc.d/listing.sh` | Shared `ll` |
| `~/.cache/ssh-prompt/bashrc.d/prompt-core.sh` | Shared command timer |
| `~/.bashrc` | Gains the marked `sshp` loader block |
| `~/.bashrc.before-sshp` | One-time backup |
| `~/.hushlogin` | Empty file suppressing the login banner |

## `bashrc.d/environment.sh`

**This file must be adapted before real use.** As shipped it contains one
developer's Windows/Git-Bash environment:

```bash
JMETER_PATH=/c/Users/<name>/sources/.../apache-jmeter-5.4.3/bin
export PATH="/c/Program Files/Microsoft/jdk-21.0.5.11-hotspot/bin:$JMETER_PATH:$PATH"
export ANDROID_HOME="/c/Users/<name>/.jdks/android-sdks"
export MAVEN_OPTS="-Djavax.net.ssl.keyStore=$HOME/.m2/cacerts ... -Djavax.net.ssl.trustStorePassword=changeit"
```

Points to be aware of:

- The paths are Git-Bash style (`/c/...`) and will not exist on Linux.
- `PATH` is **prepended** on every load, so re-sourcing `~/.bashrc` in the same
  shell accumulates duplicate entries. Harmless but untidy; guard the assignment
  if it bothers you.
- `MAVEN_OPTS` hard-codes the keystore password `changeit`. That is the standard
  Java default and not a secret, but real credentials should go into `local.sh`,
  which is gitignored.

Since this file is versioned, machine-specific values conflict on every pull. A
common pattern is to reduce it to shared defaults and move everything personal
into `local.sh`.

## `local.sh`

Copy the template and edit:

```bash
cp local.sh.example local.sh
```

It is sourced near the end of `bashrc.sh`, only if readable: after the common
history/listing/SSH modules and immediately before the local prompt backend is
selected. That lets it select and configure the prompt without being sourced
twice. It is covered by `.gitignore` along with `*.bak`, `*.backup`, `.idea`
and `*.iml`.

Prompt selection example:

```bash
BASH_PROMPT_BACKEND=starship
# BASH_PROMPT_BACKEND=bash-git-prompt
# BASH_PROMPT_BACKEND=gruvbox
# BASH_PROMPT_BACKEND=auto
```

Open a new shell after changing the value. `auto` keeps the previous behaviour:
Starship if the `starship` executable is available, otherwise the pure-Bash
Gruvbox prompt. If an explicitly selected external backend is unavailable,
`bashrc.sh` prints a warning and falls back to Gruvbox.

## Recipes

**Work against a test fixture instead of your real files**

```bash
SSH_KNOWN_HOSTS_FILE=tests/known_hosts.fixture known-hosts --lines
```

**Slow link, generous timeouts**

```bash
SSH_RESOLVE_IP_TIMEOUT=10 ssh-resolve-ips
SSH_RESOLVE_HOST_TIMEOUT=10 ssh-resolve-hosts
SSH_KNOWN_HOSTS_CLEAN_TIMEOUT=10 known-hosts --clean
```

**Quieter remote prompt** — put this in `local.sh` before any sync, so the
setting is present when `prompt.sh` builds the prompt:

```bash
export SSH_PROMPT_SHOW_COMMAND=0
```

Note that `prompt.sh` runs on the remote host, so the variable has to reach it —
either via your SSH `SendEnv`/`AcceptEnv` configuration or by setting it in the
remote shell.

**Separate config for a customer environment**

```bash
export SSH_CONFIG_FILE=~/.ssh/config.customer
export SSH_KNOWN_HOSTS_FILE=~/.ssh/known_hosts.customer
known-hosts
```

All helpers then pass `-F "$SSH_CONFIG_FILE"` to `ssh -G` automatically.
