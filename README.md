# bash-ssh-prompt

A versioned, modular Bash configuration with a command timer, a rich prompt, and
a set of SSH helper tools. After installation your real `~/.bashrc` contains
nothing but a three-line loader; everything else lives in this Git checkout.

The distinctive feature is `sshp`: it copies the prompt files to a remote host
before logging in, so you get the same prompt, command timer and `ll` listing on
every server you connect to — without installing anything there by hand.

> **Note on language:** this documentation is in English, but the shell scripts
> themselves print German messages and use German column headers
> (`ZIEL`, `BENUTZER`, `SCHLÜSSEL`, …). Command names, options and environment
> variables are the same in both languages.

## Features

| Area | What you get |
|---|---|
| Prompt | Two-line prompt, exit code, command duration, cwd, terminal window title, optional `bash-git-prompt` integration |
| Remote prompt | The same prompt on remote hosts, pushed automatically by `sshp` |
| Listing | `ll` — GNU `ls` output reformatted with aligned columns, no group column, colour-coded owner |
| History | Large history, timestamps, append-on-exit |
| SSH overview | `known-hosts` — one readable row per target, with a stable target number |
| SSH cleanup | `known-hosts-clean` — verify `known_hosts` against live host keys, drop stale entries and matching config aliases |
| SSH login | `ssh-nr N` — connect by target number; `ssh` and `sshp` share one argument parser, so plain logins are transparently routed through `sshp` |
| SSH DNS | `ssh-resolve-ips` — reverse-resolve every IP referenced in your config or `known_hosts` |
| Completion | Tab completion for `ssh`, `sshp` and all helpers, with a lazy cache that notices config changes |
| Discoverability | `bash-commands` — list every command this configuration adds, with a `--check` self-test |

## Requirements

**Local machine**

- Bash 4.2 or newer (5.x recommended; `EPOCHREALTIME` and array-valued
  `PROMPT_COMMAND` are used when available, with fallbacks)
- GNU coreutils (`ls`, `date`, `mktemp`, `cksum`) and an `awk`
- OpenSSH client: `ssh`, `ssh-keygen`, `ssh-keyscan`
- `tar` and `gzip` for `sshp`
- Optional: [`bash-git-prompt`](https://github.com/magicmonty/bash-git-prompt)
  checked out at `~/.bash-git-prompt`
- Optional, for reverse DNS: `getent`, `dig`, `host`, `nslookup` or
  `powershell.exe` (Git Bash on Windows)

**Remote hosts**

- Bash, plus `tar`, `grep`, `mktemp` and `touch`
- GNU `ls` if you want the `ll` listing to render correctly

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

**Before you use it for real**, edit `bashrc.d/environment.sh`. As shipped it
contains one developer's hard-coded Windows paths for the JDK, JMeter, the
Android SDK and Maven. See [docs/configuration.md](docs/configuration.md#bashrcdenvironmentsh).

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
ssh myserver            # plain logins are routed through sshp
ssh -p 2222 myserver    # OpenSSH options are passed through
sshp --force myserver   # force a prompt re-sync before logging in
ssh --help              # own switches plus the real client's option list

ssh-resolve-ips         # reverse-DNS for all IPs in config + known_hosts
known-hosts-clean       # dry run: what would be removed?
known-hosts-clean --apply    # actually clean up (creates backups)
```

The first `sshp` call to a host after you change a prompt file opens two SSH
connections: one to sync, one to log in. Unchanged calls open just one.

## Repository layout

```
install.sh                 Installs the ~/.bashrc loader, with backup
bashrc.sh                  Entry point: loads every module in order
bashrc.snippet.sh          Reference snippet for manual setup (legacy)
local.sh.example           Template for untracked machine-local settings
prompt.sh                  Prompt used on remote hosts (synced by sshp)
ssh-prompt.sh              sshp: sync + login, and the ssh() wrapper
.git-prompt-colors.sh      Custom theme for bash-git-prompt

bashrc.d/
  environment.sh           JDK, JMeter, Android, Maven  (edit this!)
  history.sh               History size, timestamps, append mode
  listing.sh               Shared ll implementation
  prompt-core.sh           Command timer and window title (local + remote)
  prompt-local.sh          bash-git-prompt wiring for local shells
  ssh-tools.sh             Loader for the SSH helpers, aliases, completion
  commands.sh              bash-commands: overview of all provided commands
  lib/
    ssh-config.sh          Shared ~/.ssh/config scanner (incl. Include)
    known-hosts.sh         known-hosts overview and grouping model
    known-hosts-clean.sh   known-hosts-clean
    ssh-by-number.sh       ssh-nr
    ssh-resolve-ips.sh     ssh-resolve-ips
  completions/             Bash completion for all of the above

tests/
  known-hosts.sh           Regression test for the known-hosts parser
  known_hosts.fixture      Synthetic parser data (no real keys)
```

## Documentation

| Document | Contents |
|---|---|
| [docs/installation.md](docs/installation.md) | Install, update, uninstall, manual setup, remote-side changes |
| [docs/prompt.md](docs/prompt.md) | Prompt, command timer, window title, `ll`, history, git theme |
| [docs/ssh-sync.md](docs/ssh-sync.md) | How `sshp` works: signatures, state, remote payload, troubleshooting |
| [docs/ssh-tools.md](docs/ssh-tools.md) | `known-hosts`, `known-hosts-clean`, `ssh-nr`, `ssh-resolve-ips`, completion |
| [docs/configuration.md](docs/configuration.md) | Every environment variable and file path, with defaults |
| [docs/architecture.md](docs/architecture.md) | Load order, naming conventions, caches, tests, known limitations |

Start with [docs/architecture.md#known-limitations](docs/architecture.md#known-limitations)
if something behaves differently than described — there are a few known rough
edges, in particular a load-order clash between the two `ssh` wrappers.

## Testing

```bash
bash tests/known-hosts.sh   # known-hosts parser regression test
bash-commands --check       # every documented command is really defined
```

`TEST.md` (German) records a manual test run of the whole package from
8 September 2026. See [docs/architecture.md#testing](docs/architecture.md#testing).

## Safety notes

- `sshp` appends a marked block to the **remote** `~/.bashrc` and creates
  `~/.hushlogin` there. Both are reversible; see
  [docs/installation.md#what-sshp-changes-on-a-remote-host](docs/installation.md#what-sshp-changes-on-a-remote-host).
- `known-hosts-clean` treats an unreachable host as stale and would remove it.
  Always run the dry run first, and never run `--apply` while off the VPN.
- `known-hosts` and `ssh-resolve-ips` run `ssh -G`, which does not open a
  connection but does evaluate `Match exec` rules from your config.
