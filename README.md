# bash-ssh-prompt

A versioned, modular Bash configuration with a command timer, a rich prompt, and
a set of SSH helper tools. After installation your real `~/.bashrc` contains
nothing but a three-line loader; everything else lives in this Git checkout.

The distinctive feature is `sshp`: it copies the prompt files to a remote host
before logging in, so you get the same prompt, command timer and `ll` listing on
every server you connect to — without installing anything there by hand.

> **Note on language:** documentation, messages and column headers are all in
> English. Earlier versions shipped a German UI; the German option synonym
> `--zeilen` for `known-hosts --lines` no longer exists.

## Features

| Area | What you get |
|---|---|
| Prompt | Selectable local backend: Starship, `bash-git-prompt`, or the pure-Bash Gruvbox Powerline; exit code, duration, cwd and window title |
| Remote prompt | The same prompt on remote hosts, pushed automatically by `sshp` |
| Listing | `ll` — GNU `ls` output reformatted with aligned columns, no group column, colour-coded owner |
| History | Large history with timestamps, written after every command instead of only on exit, and kept free of duplicates |
| SSH overview | `known-hosts` — one readable row per target, with a stable target number |
| SSH cleanup | `known-hosts --clean` — verify `known_hosts` against live host keys, drop stale entries and matching config aliases |
| SSH login | `sshp HOST` — sync the prompt, then log in; `ssh-nr N` — connect by target number. Plain `ssh` is left untouched and stays the OpenSSH client |
| SSH DNS | `ssh-resolve-ips` and `ssh-resolve-hosts` — resolve every IP and every hostname referenced in your config or `known_hosts`, in both directions |
| Completion | Tab completion for `ssh`, `sshp` and all helpers, with a lazy cache that notices config changes |
| Discoverability | `bash-commands` — list every command this configuration adds, with a `--check` self-test |

## Requirements

**Local machine**

- Bash 4.2 or newer (5.x recommended; `EPOCHREALTIME` and array-valued
  `PROMPT_COMMAND` are used when available, with fallbacks)
- GNU coreutils (`ls`, `date`, `mktemp`, `cksum`) and an `awk`
- OpenSSH client: `ssh`, `ssh-keygen`, `ssh-keyscan`
- `tar` and `gzip` for `sshp`
- Optional: [Starship](https://starship.rs/) for the versioned `starship.toml` backend
- Optional: [`bash-git-prompt`](https://github.com/magicmonty/bash-git-prompt)
  checked out at `~/.bash-git-prompt`
- Optional, for reverse DNS: `getent`, `dig`, `host`, `nslookup` or
  `powershell.exe` (Git Bash on Windows)

**Remote hosts**

- Bash, plus `tar`, `grep`, `mktemp` and `touch`
- GNU `ls` if you want the `ll` listing to render correctly

A remote host with Bash older than 4.2 gets a simpler fallback prompt: the
powerline prompt needs associative arrays and `$'\Uxxxxxxxx'`, which such a
shell cannot even parse. Stock macOS ships Bash 3.2, so a Mac lands there by
default; the command timer, the exit code and the repeated command work the
same, only the powerline segments are plain.

The project targets both Linux and Git Bash on Windows.

## Installation

Clone the repository, then run the installer from inside it:

```bash
git clone <url> ~/src/bash-ssh-prompt
cd ~/src/bash-ssh-prompt
bash install.sh
source ~/.bashrc
```

`install.sh` syntax-checks the core files, backs up any existing `~/.bashrc` to
`~/.bashrc.before-modular-config.<timestamp>`, and replaces it with a loader
pointing at your checkout:

```bash
# Generated loader for the versioned Bash configuration.
BASH_CONFIG_ROOT=/home/you/src/bash-ssh-prompt
source "$BASH_CONFIG_ROOT/bashrc.sh"
```

Because the loader references the checkout by absolute path, moving the
repository means re-running `install.sh`.

### Choose the local prompt

Set `BASH_PROMPT_BACKEND` in the untracked `local.sh` and open a new shell:

```bash
BASH_PROMPT_BACKEND=starship         # versioned starship.toml
BASH_PROMPT_BACKEND=bash-git-prompt  # bashrc.d/prompt-local.sh
BASH_PROMPT_BACKEND=gruvbox          # bashrc.d/prompt-gruvbox.sh
BASH_PROMPT_BACKEND=auto             # Starship if installed, otherwise Gruvbox
```

`prompt-local` is accepted as an alias for `bash-git-prompt`; `prompt-gruvbox`
and `prompt-gruvbox.sh` are aliases for `gruvbox`. An explicitly selected
backend that is not installed falls back to the pure-Bash Gruvbox prompt with a
warning.

`bashrc.d/environment.sh` ships empty. It is the versioned place for
machine-specific exports; anything that must not be committed goes into the
untracked `local.sh` instead. See
[docs/configuration.md](docs/configuration.md#bashrcdenvironmentsh).

Details, uninstall instructions and the manual-setup alternative are in
[docs/installation.md](docs/installation.md).

## Quick tour

```bash
bash-commands           # what does this configuration give me?
bash-commands --details # ... with call syntax and defining file

ll                      # aligned, colour-coded directory listing
known-hosts             # overview of every known SSH target, numbered
known-hosts srv         # case-insensitive substring filter
known-hosts --lines     # also show known_hosts line numbers
known-hosts --fingerprints   # original ssh-keygen fingerprint output

ssh-nr 4                # log in to target number 4 from the list above
sshp myserver           # sync the prompt files, then log in
sshp -p 2222 myserver   # OpenSSH options are passed through
sshp --force myserver   # force a prompt re-sync before logging in
sshp --help             # own switches plus the real client's option list
# SSHP_WARN_WEAK_CRYPTO=yes is the default; set it to no to suppress
# OpenSSH's weak-crypto warning when the installed client supports the option.
ssh myserver            # untouched OpenSSH: no sync, no prompt

ssh-resolve-ips         # reverse-DNS: IPs   -> hostnames
ssh-resolve-hosts       # forward-DNS: hosts -> IPs
known-hosts --clean          # dry run: what would be removed?
known-hosts --clean --apply  # actually clean up (creates backups)
```

The first `sshp` call to a host after you change a prompt file opens two SSH
connections: one to sync, one to log in. Unchanged calls open just one.

## Repository layout

```
install.sh                 Installs the ~/.bashrc loader, with backup
bashrc.sh                  Entry point: loads every module in order
local.sh.example           Template for untracked settings and prompt selection
starship.toml              Versioned Gruvbox Starship theme
prompt.sh                  Remote wiring: welcome banner + gruvbox prompt (synced by sshp)
ssh-prompt.sh              sshp: prompt sync + login
.git-prompt-colors.sh      Custom theme for bash-git-prompt

bashrc.d/
  environment.sh           Empty hook for machine-specific exports
  history.sh               History sizes, timestamps, crash-safe writing, dedup
  listing.sh               Shared ll implementation
  prompt-core.sh           Command timer and window title (local + remote)
  prompt-local.sh          bash-git-prompt wiring for local shells
  prompt-gruvbox.sh        Pure-Bash Gruvbox Powerline prompt (local + remote)
  ssh-tools.sh             Loader for the SSH helpers, aliases, completion
  commands.sh              bash-commands: overview of all provided commands
  lib/
    ssh-config.sh          Config scanner, shared SSH inventory cache and primitives
    known-hosts.sh         known-hosts: cache, grouping model, display
    known-hosts-clean.sh   known-hosts --clean
    ssh-by-number.sh       ssh-nr
    ssh-resolve.sh         Shared table behind both resolvers
    ssh-resolve-ips.sh     ssh-resolve-ips: reverse direction only
    ssh-resolve-hosts.sh   ssh-resolve-hosts: forward direction only
  completions/             Bash completion for all of the above
                           (ssh-resolve.bash serves both resolvers)

tests/
  run-all.sh               Runs every test script, one summary line each
  lib.sh                   Assertions and the sandbox/stub helpers
  install.sh               install.sh loader, backup, syntax gate
  history.sh               History deduplication and writing
  listing.sh               ll formatting
  prompt-core.sh           Command timer and window title
  bashrc-integration.sh    Full startup hook composition for all prompt backends
  prompt-gruvbox.sh        Gruvbox prompt regression test
  prompt-local.sh          bash-git-prompt status segment regression test
  prompt-selection.sh      local.sh backend selector regression test
  remote-prompt.sh         Remote wiring and the pre-4.2 fallback prompt
  ssh-config.sh            Scanner plus shared config/known_hosts inventory cache
  known-hosts.sh           known-hosts parser and process count
  known-hosts-clean.sh     known-hosts --clean, dry run and --apply
  ssh-by-number.sh         ssh-nr target resolution
  ssh-resolve.sh           IP predicates, resolver options, load-order guards
  ssh-resolve-table.sh     The shared resolver table end to end
  sshp.sh                  sshp argument parser and guards
  commands.sh              bash-commands listing and self-check
  completion.sh            Host cache and all completion functions
  starship-config.sh       starship.toml layout and palette regression test
  integration/
    bash-git-prompt.sh     Compatibility check against pinned upstream 2.7.1 in CI
  known_hosts.fixture      Synthetic parser data (no real keys)
```

## Documentation

| Document | Contents |
|---|---|
| [docs/installation.md](docs/installation.md) | Install, update, uninstall, manual setup, remote-side changes |
| [docs/prompt.md](docs/prompt.md) | Prompt, command timer, window title, `ll`, history, git theme |
| [docs/ssh-sync.md](docs/ssh-sync.md) | How `sshp` works: signatures, state, remote payload, troubleshooting |
| [docs/ssh-tools.md](docs/ssh-tools.md) | `known-hosts` incl. `--clean`, `ssh-nr`, `ssh-resolve-ips`, completion |
| [docs/configuration.md](docs/configuration.md) | Every environment variable and file path, with defaults |
| [docs/architecture.md](docs/architecture.md) | Load order, naming conventions, caches, tests, known limitations |

Start with [docs/architecture.md#known-limitations](docs/architecture.md#known-limitations)
if something behaves differently than described — there are a few known rough
edges.

## Testing

```bash
bash tests/run-all.sh       # the whole suite
bash tests/history.sh       # or a single script
bash-commands --check       # every documented command is really defined
```

Currently 19 scripts with 574 checks, all passing. The same three commands run
in CI on every push, together with a `bash -n` gate over the whole tree
(`.github/workflows/ci.yml`).

The regular suite runs against throwaway home directories and stubbed `ssh`,
`ssh-keygen` and `ssh-keyscan` binaries, so it touches neither your own
configuration nor the network. CI additionally checks the local prompt against
the pinned `bash-git-prompt` 2.7.1 checkout.

`TEST.md` records what the suite covers plus a manual test run of the whole
package. See [docs/architecture.md#testing](docs/architecture.md#testing).

## Safety notes

- `sshp` appends a marked block to the **remote** `~/.bashrc` and creates
  `~/.hushlogin` there. Both are reversible; see
  [docs/installation.md#what-sshp-changes-on-a-remote-host](docs/installation.md#what-sshp-changes-on-a-remote-host).
- `known-hosts --clean` treats an unreachable host as stale and would remove it.
  Always run the dry run first, and never run `--apply` while off the VPN.
- `known-hosts`, `ssh-resolve-ips` and `ssh-resolve-hosts` run `ssh -G`, which
  does not open a connection but does evaluate `Match exec` rules from your
  config.
