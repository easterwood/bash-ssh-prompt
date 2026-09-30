# Installation

## Automatic installation

Run the installer from inside the checkout:

```bash
cd /path/to/bash-ssh-prompt
bash install.sh
source ~/.bashrc
```

`install.sh` runs with `set -euo pipefail` and performs these steps:

1. Determines the checkout root from its own location (`pwd -P`, so symlinks are
   resolved).
2. Syntax-checks a fixed list of files with `bash -n`:
   `bashrc.sh`, `prompt.sh`, `ssh-prompt.sh`, `.git-prompt-colors.sh`, and the
   seven modules in `bashrc.d/`. If any of them fails, nothing is changed.
3. If `~/.bashrc` exists, copies it (preserving attributes) to
   `~/.bashrc.before-modular-config.<YYYYmmdd-HHMMSS>` and prints the path.
4. Overwrites `~/.bashrc` with a three-line loader. The checkout path is written
   through `printf %q`, so paths with spaces or special characters are safe.
5. Syntax-checks the generated `~/.bashrc` and prints the reload command.

> `source ~/.bashrc` is enough for everything except the history cleanup.
> `history_dedupe` rewrites `~/.bash_history` before Bash reads it, and in an
> already running shell the list in memory is written back on exit. Open a new
> terminal to see the deduplicated history.

The generated loader:

```bash
# Generated loader for the versioned Bash configuration.
BASH_CONFIG_ROOT=/home/you/src/bash-ssh-prompt
source "$BASH_CONFIG_ROOT/bashrc.sh"
```

> `install.sh` does **not** syntax-check `bashrc.d/lib/*.sh` or
> `bashrc.d/completions/*.bash`. A syntax error in one of those files will only
> surface when you open a new shell. See
> [architecture.md#known-limitations](architecture.md#known-limitations).

## First-run configuration

`bashrc.d/environment.sh` ships empty. It is the versioned hook for
machine-specific exports and needs no editing before first use.

Anything that must not be committed, plus the choice of prompt backend, belongs
in the untracked `local.sh`:

```bash
cp local.sh.example local.sh
```

`local.sh` is optional and is listed in `.gitignore` together with `*.bak`,
`*.backup`, `.idea` and `*.iml`. It is loaded immediately after
`environment.sh`, before modules with source-time settings and before the local
prompt backend is initialized.

For example:

```bash
BASH_PROMPT_BACKEND=starship
# BASH_PROMPT_BACKEND=bash-git-prompt
# BASH_PROMPT_BACKEND=gruvbox
# BASH_PROMPT_BACKEND=auto
```

Open a new shell after changing the backend.

## Optional: Starship

Install `starship` and select it in `local.sh`:

```bash
BASH_PROMPT_BACKEND=starship
```

The configuration sets `STARSHIP_CONFIG` to the versioned `starship.toml`
unless you already set `STARSHIP_CONFIG` yourself.

## Optional: bash-git-prompt

`bashrc.d/prompt-local.sh` sources `~/.bash-git-prompt/gitprompt.sh` if it
exists, and configures the bundled `Custom` theme. Without it the local prompt
simply has no Git segment; nothing breaks. To install it:

```bash
git clone https://github.com/magicmonty/bash-git-prompt.git ~/.bash-git-prompt
```

The theme file used is `$BASH_CONFIG_ROOT/.git-prompt-colors.sh`, i.e. the one
in this repository — see [prompt.md](prompt.md#git-prompt-theme).

## Verifying the installation

```bash
bash -n ~/.bashrc          # loader is syntactically valid
source ~/.bashrc
type ll sshp known-hosts   # all defined
echo "$BASH_CONFIG_ROOT"   # points at your checkout
bash tests/known-hosts.sh  # parser regression test passes
```

In a freshly opened terminal, check that the history is being written
immediately instead of only on exit:

```bash
echo "$HISTFILE"                    # ~/.bash_history
declare -p PROMPT_COMMAND           # contains __history_append
echo history-probe
tail -2 "$HISTFILE"                 # the probe is already there
```

## Updating

```bash
cd /path/to/bash-ssh-prompt
git pull
source ~/.bashrc
```

If `prompt.sh`, `bashrc.d/listing.sh`, `bashrc.d/prompt-core.sh` or
`bashrc.d/prompt-gruvbox.sh` changed, the
next `sshp`/`ssh` to each host will re-sync automatically, because the sync
signature no longer matches the stored state. You do not need to clear anything
by hand — but `sshp --force HOST` will re-sync unconditionally.

If you move or rename the checkout, re-run `bash install.sh`, because the loader
in `~/.bashrc` holds an absolute path.

## Uninstalling

**Local machine**

```bash
# restore the most recent pre-install backup
ls -t ~/.bashrc.before-modular-config.* | head -1
cp ~/.bashrc.before-modular-config.<timestamp> ~/.bashrc

# optional: drop the sync state cache
rm -rf ~/.cache/sshp
```

**Remote hosts** — see below.

## What `sshp` changes on a remote host

The first successful sync to a host makes these changes in the remote `$HOME`:

| Path | Purpose |
|---|---|
| `~/.cache/ssh-prompt/prompt.sh` | The synced remote prompt |
| `~/.cache/ssh-prompt/bashrc.d/listing.sh` | Shared `ll` |
| `~/.cache/ssh-prompt/bashrc.d/prompt-core.sh` | Shared command timer |
| `~/.cache/ssh-prompt/bashrc.d/prompt-gruvbox.sh` | Shared powerline prompt (Git segment off on remote hosts) |
| `~/.bashrc` | Gains a marked loader block (see below) |
| `~/.bashrc.before-sshp` | One-time backup, created only if `~/.bashrc` existed |
| `~/.hushlogin` | Created (empty) to suppress post-authentication MOTD/last-login output |

The block appended to the remote `~/.bashrc` is written exactly once, guarded by
its start marker:

```bash
# >>> sshp managed prompt >>>
if [[ -n ${SSH_CONNECTION-} && -r "$HOME/.cache/ssh-prompt/prompt.sh" ]]; then
    source "$HOME/.cache/ssh-prompt/prompt.sh"
fi
# <<< sshp managed prompt <<<
```

Because it is guarded by `SSH_CONNECTION`, local shells on that host are
unaffected, and removing `~/.cache/ssh-prompt` disables the prompt without
breaking login.

The remote script runs under `umask 077`, extracts with `tar --no-same-owner`,
`bash -n`-checks all three files before touching `~/.bashrc`, writes the new
`.bashrc` to a `mktemp` file, `chmod 600`s it and moves it into place
atomically.

**To undo on a remote host:**

```bash
rm -rf ~/.cache/ssh-prompt
# then delete the marked block from ~/.bashrc, or:
cp ~/.bashrc.before-sshp ~/.bashrc
rm -f ~/.hushlogin
```

Afterwards remove the matching local state file so the next login re-syncs:

```bash
rm -rf ~/.cache/sshp
```

## Manual setup (without `install.sh`)

You can source `bashrc.sh` from an existing `~/.bashrc` instead of letting the
installer replace it:

```bash
BASH_CONFIG_ROOT=/path/to/bash-ssh-prompt
source "$BASH_CONFIG_ROOT/bashrc.sh"
```

`bashrc.sh` recomputes `BASH_CONFIG_ROOT` from its own location anyway, so the
assignment above is only documentation.

Nothing else needs to be added to `~/.bashrc`.
