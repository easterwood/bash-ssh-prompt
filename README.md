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
| Prompt | Two-line prompt, exit code, command duration, cwd, terminal window title, optional `bash-git-prompt` integration |
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
sshp myserver           # sync the prompt files, then log in
sshp -p 2222 myserver   # OpenSSH options are passed through
sshp --force myserver   # force a prompt re-sync before logging in
sshp --help             # own switches plus the real client's option list
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
bashrc.snippet.sh          Reference snippet for manual setup (legacy)
local.sh.example           Template for untracked machine-local settings
prompt.sh                  Prompt used on remote hosts (synced by sshp)
ssh-prompt.sh              sshp: prompt sync + login
.git-prompt-colors.sh      Custom theme for bash-git-prompt

bashrc.d/
  environment.sh           JDK, JMeter, Android, Maven  (edit this!)
  history.sh               History sizes, timestamps, crash-safe writing, dedup
  listing.sh               Shared ll implementation
  prompt-core.sh           Command timer and window title (local + remote)
  prompt-local.sh          bash-git-prompt wiring for local shells
  ssh-tools.sh             Loader for the SSH helpers, aliases, completion
  commands.sh              bash-commands: overview of all provided commands
  lib/
    ssh-config.sh          Shared ~/.ssh/config scanner (incl. Include)
    known-hosts.sh         known-hosts: overview, grouping model, --clean
    ssh-by-number.sh       ssh-nr
    ssh-resolve-ips.sh     ssh-resolve-ips
    ssh-resolve-hosts.sh   ssh-resolve-hosts (reuses helpers from the above)
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
| [docs/ssh-tools.md](docs/ssh-tools.md) | `known-hosts` incl. `--clean`, `ssh-nr`, `ssh-resolve-ips`, completion |
| [docs/configuration.md](docs/configuration.md) | Every environment variable and file path, with defaults |
| [docs/architecture.md](docs/architecture.md) | Load order, naming conventions, caches, tests, known limitations |

Start with [docs/architecture.md#known-limitations](docs/architecture.md#known-limitations)
if something behaves differently than described — there are a few known rough
edges.

## Testing

```bash
bash tests/known-hosts.sh   # known-hosts parser regression test
bash-commands --check       # every documented command is really defined
```

`TEST.md` records a manual test run of the whole package from
8 September 2026. See [docs/architecture.md#testing](docs/architecture.md#testing).

## Safety notes

- `sshp` appends a marked block to the **remote** `~/.bashrc` and creates
  `~/.hushlogin` there. Both are reversible; see
  [docs/installation.md#what-sshp-changes-on-a-remote-host](docs/installation.md#what-sshp-changes-on-a-remote-host).
- `known-hosts --clean` treats an unreachable host as stale and would remove it.
  Always run the dry run first, and never run `--apply` while off the VPN.
- `known-hosts`, `ssh-resolve-ips` and `ssh-resolve-hosts` run `ssh -G`, which
  does not open a connection but does evaluate `Match exec` rules from your
  config.
