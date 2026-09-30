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
| `HISTCONTROL` | `bashrc.d/history.sh` | `erasedups:ignorespace` — a repeated command keeps only its most recent occurrence, and a command typed with a leading space is not recorded at all |
| `SSHP_WELCOME_SHOWN` | `prompt.sh` | Exported guard so the remote welcome banner appears once per connection, not in nested shells |
| `GIT_PROMPT_ONLY_IN_REPO`, `GIT_PROMPT_THEME`, `GIT_PROMPT_SHOW_UPSTREAM`, `GIT_PROMPT_THEME_FILE` | `bashrc.d/prompt-local.sh` | `bash-git-prompt` layout settings |
| `GIT_PROMPT_FETCH_REMOTE_STATUS`, `GIT_PROMPT_SHOW_UNTRACKED_FILES`, `GIT_PROMPT_IGNORE_SUBMODULES`, `GIT_PROMPT_WITH_VIRTUAL_ENV`, `GIT_PROMPT_SHOW_CHANGED_FILES_COUNT` | `bashrc.d/prompt-local.sh` | `bash-git-prompt` performance settings |

### Read by the configuration

Set these before sourcing, in `local.sh`, or per command.

| Variable | Default | Read by | Effect |
|---|---|---|---|
| `SSH_KNOWN_HOSTS_FILE` | `~/.ssh/known_hosts` | `known-hosts` (incl. `--clean`), `ssh-nr`, `ssh-resolve-ips`, all completions | Which `known_hosts` file to use |
| `SSH_CONFIG_FILE` | `~/.ssh/config` | same as above | Which SSH config to treat as primary. When it differs from the default, the tools pass `-F` explicitly |
| `SSH_RESOLVE_IP_TIMEOUT` | `3` | `ssh-resolve-ips` | Reverse-DNS timeout in seconds. Must be a positive integer |
| `SSH_RESOLVE_HOST_TIMEOUT` | `3` | `ssh-resolve-hosts` | Forward-DNS timeout in seconds. Must be a positive integer |
| `SSH_KNOWN_HOSTS_CLEAN_TIMEOUT` | `3` | `known-hosts --clean` | `ssh-keyscan` timeout in seconds. Must be a positive integer |
| `SSH_PROMPT_SHOW_COMMAND` | `1` | `prompt.sh` | `0` hides the repetition of the last command in the remote prompt (it seeds `PROMPT_GRUVBOX_SHOW_COMMAND`) |
| `SSHP_WARN_WEAK_CRYPTO` | `yes` | `ssh-prompt.sh` / `sshp` | `yes` leaves OpenSSH's weak-crypto warnings enabled. `no` adds `-o WarnWeakCrypto=no` when the installed client supports that option; older clients keep their normal warning behaviour |
| `PROMPT_LOCAL_SHOW_COMMAND` | `1` | `bashrc.d/prompt-local.sh` | `0` drops the repetition of the last command from the `bash-git-prompt` status segment |
| `PROMPT_LOCAL_COMMAND_MAX_LEN` | `60` | `bashrc.d/prompt-local.sh` | Truncation length for that repetition |
| `HISTORY_DEDUPE_LIVE` | `0` | `bashrc.d/history.sh` | `0` rewrites the history file only at shell start instead of also right after a repeated command. Useful on very large history files |
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

The file ships empty and contains nothing but a shebang. It exists so that
machine-specific exports have a versioned place to go, and it is sourced first,
before every other module.

Earlier revisions of this repository shipped one developer's Git-Bash
environment here: a JMeter path, a JDK `bin` directory prepended to `PATH`,
`ANDROID_HOME`, and `MAVEN_OPTS` with a keystore under `$HOME/.m2/cacerts`.
Those values are gone. If you put your own in, two things are worth knowing:

- Anything that prepends to `PATH` runs again on every re-source, so
  `source ~/.bashrc` in the same shell accumulates duplicate entries. Guard the
  assignment if that bothers you.
- Because the file is versioned, machine-specific values conflict on every
  pull, and credentials would be committed. Both belong in the untracked
  `local.sh`, which is listed in `.gitignore`:

```bash
cp local.sh.example local.sh
```

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

Prompt and SSH policy example:

```bash
BASH_PROMPT_BACKEND=starship
# BASH_PROMPT_BACKEND=bash-git-prompt
# BASH_PROMPT_BACKEND=gruvbox
# BASH_PROMPT_BACKEND=auto

# sshp defaults to yes. This checkout currently suppresses the warning.
SSHP_WARN_WEAK_CRYPTO=no
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
