# `sshp` — prompt sync and login

`sshp` is defined in `ssh-prompt.sh`. It pushes the prompt files to a remote
host and then opens an interactive login. When nothing has changed since the
last sync to that host, it skips straight to the login, so the common case costs
exactly one SSH connection.

## Usage

```bash
sshp HOST                                # SSH config alias
sshp user@host                           # explicit user
sshp --force HOST                        # re-sync even if the signature matches
sshp -p 2222 HOST                        # OpenSSH options are passed through
sshp -J jump.example.com -i ~/.ssh/id_ed25519 db01
sshp --help
```

Exactly one destination is required, and it must come after any options.
`--force` and `--help` are `sshp`'s own switches; everything else starting with
`-` is forwarded verbatim to OpenSSH. `--` ends option parsing, so the next word
is taken as the destination.

`ssh` is not wrapped — see [Plain `ssh` is not touched](#plain-ssh-is-not-touched).

Parsing lives in `__sshp_parse_args`, which fills `__sshp_options`,
`__sshp_target`, `__sshp_extra`, `__sshp_force` and `__sshp_help_requested`.
The completion for the destination argument uses the same option table, which
is what keeps parsing and completion in sync.

Errors all return exit code `2` with a usage block:

| Situation | Message |
|---|---|
| No destination given | `sshp: exactly one SSH destination is required.` |
| An option's argument is missing (e.g. a trailing `-p`) | `sshp: the argument for the last option is missing.` |
| Words remain after the destination | `sshp: a remote command is not supported: …` |

A remote command is rejected on purpose: `sshp` always ends in an interactive
login, so `sshp host uname -a` would sync the prompt for nothing. Use
`ssh host uname -a` instead.

The whole function body is a subshell (`sshp() ( … )`), so its `local`
variables, `trap` and working state cannot leak into your interactive shell.


## Sync status

A cache miss can take a moment because `sshp` has to build the prompt archive,
open a separate SSH connection, install and validate the files remotely, then
write the local sync state. On an interactive terminal, `SSHP_SYNC_STATUS=yes`
(the default) visualises those phases with a small ASCII spinner:

```text
[|] sshp: preparing prompt package...
[/] sshp: uploading and installing prompt...
[-] sshp: saving sync state...
[ok] sshp: prompt synchronized
```

The spinner updates one terminal line rather than printing a new line for every
frame. It is written only to `stderr`, is automatically disabled when stderr is
not a TTY or when `TERM=dumb`, and never starts on a cache hit. This keeps
redirected output, command substitutions and scripts unchanged. Set
`SSHP_SYNC_STATUS=no` to disable it explicitly.

On a sync failure the animation is cleared and ends with
`[!!] sshp: prompt synchronization failed` before the existing error details.
The local cleanup trap also stops the spinner on `HUP`, `INT` and `TERM`, so an
interrupted sync cannot leave a background animation running.

The internal upload/install SSH connection uses `LogLevel=ERROR`. OpenSSH only
prints the server's pre-authentication `SSH_MSG_USERAUTH_BANNER` at `INFO` or
higher, so a legal/login banner is hidden during synchronization and appears
only on the following real interactive login. `~/.hushlogin` is still created
for its separate post-authentication MOTD/last-login behaviour. User `-v` flags
are retained for the real login but intentionally omitted from the sync call.

## Option pass-through

Options are collected into one array that is used for **both** the sync
connection and the login connection, so `-p`, `-F`, `-J`, `-i` and friends apply
consistently — a target on a non-standard port syncs over that same port.

`sshp` leaves OpenSSH's weak-crypto warning enabled by default. With the
default `SSHP_WARN_WEAK_CRYPTO=yes`, no `WarnWeakCrypto` option is added:

```
sync:   ssh -T -o RemoteCommand=none <your options> HOST
login:  ssh <your options> HOST
```

Set `SSHP_WARN_WEAK_CRYPTO=no` to suppress that warning. `sshp` first probes
the installed client with `ssh -G`; if the option is supported, the calls
become:

```
sync:   ssh -T -o RemoteCommand=none -o WarnWeakCrypto=no <your options> HOST
login:  ssh -o WarnWeakCrypto=no <your options> HOST
```

If the client predates `WarnWeakCrypto`, the option is omitted and the client's
normal warning behaviour is left intact. The probe performs configuration
expansion only; it does not open a network connection.

The order matters. For `-o` settings OpenSSH keeps the **first** value it sees,
so `RemoteCommand=none` cannot be overridden by a `RemoteCommand` in your
config. When warning suppression is enabled, the sshp-owned
`WarnWeakCrypto=no` is likewise placed before user-supplied options.

`__sshp_option_takes_arg` knows which OpenSSH options consume the following
word (`-B -b -c -D -E -e -F -I -i -J -L -l -m -O -o -P -p -Q -R -S -W -w`), so
both `-p 2222` and the attached form `-p2222` are parsed correctly and the
destination is never mistaken for an option argument.

> Before checking the sync cache, `sshp` runs `ssh -G` locally and derives a
> connection identity from the effective `hostname`, `user`, `port`, address
> family, proxy route and host-key alias. Different ports or SSH configs that
> resolve the same alias to different endpoints therefore use different state.

## Plain `ssh` is not touched

This configuration does not define an `ssh` function or alias. `ssh` is the
OpenSSH client from your `PATH`, with all options, all exit codes and the
distribution's own behaviour. The prompt sync happens only when you ask for it:

| Command | What happens |
|---|---|
| `sshp server` | sync if needed, then log in |
| `ssh server` | native OpenSSH, no sync, no synced prompt |
| `ssh server uname -a` | native OpenSSH, as always |
| `ssh-nr 4` | resolves the target number and calls `sshp` |

Only `sshp` and the helper commands are added; `ssh` keeps host completion from
`ssh-tools.sh`, because that is useful regardless of which of the two you use.

> An earlier version shipped an `ssh()` wrapper here that forwarded plain
> interactive logins to `sshp` and everything else to OpenSSH. It has been
> removed. If you want that behaviour back for individual hosts, put a minimal
> variant into your own `local.sh`:
>
> ```bash
> ssh() {
>     if (( $# == 1 )) && [[ $1 == devbox || $1 == testbox ]]; then
>         sshp "$1"
>     else
>         command ssh "$@"
>     fi
> }
> ```

## `--help`

`sshp --help` prints a three-part help: the synopsis with `sshp`'s own
switches, a paragraph on how options are forwarded, and then the option list of
the **installed** OpenSSH client, so you do not have to switch commands to look
up a flag:

```
Usage: sshp [--force] [SSH-OPTIONS ...] user@host
       sshp [--force] [SSH-OPTIONS ...] SSH-config-alias

  --force   Copy the prompt files even if the signature matches
  --help    Show this help

SSH options are passed through to OpenSSH unchanged and apply to
...

Options passed through to /usr/bin/ssh (OpenSSH_9.6p1, OpenSSL 3.0.13):

  usage: ssh [-46AaCfGgKkMNnqsTtVvXxYy] [-B bind_interface]
             [-b bind_address] [-c cipher_spec] ...
```

That last block is not a copy kept in this repository. `__sshp_ssh_usage`
locates the binary with `type -P ssh`, reads the version from `ssh -V`, and runs
the binary with no arguments — OpenSSH then prints its usage block on stderr and
exits 255. So the list always matches the client actually installed, and it
degrades gracefully to a one-line note if no `ssh` is in `PATH`.

## Which files are synced

```
prompt.sh
bashrc.d/listing.sh
bashrc.d/prompt-core.sh
bashrc.d/prompt-gruvbox.sh
```

Before anything is transferred, each file must exist, be readable, and pass
`bash -n`. A syntax error aborts the whole call — you never push a broken prompt
to a server.

## How change detection works

1. A **signature** is computed locally: the literal format tag
   `sshp-sync-format=5`, then for each file its relative path and its `cksum`
   output, all piped through `cksum` again. Bumping the format tag in a future
   version therefore invalidates every stored state at once.
2. `ssh -G` resolves the destination plus forwarded SSH options without opening
   a connection. `sshp` retains the effective `hostname`, `user`, `port`,
   `addressfamily`, `proxyjump`, `proxycommand` and `hostkeyalias` fields as the
   **connection identity**.
3. That identity is hashed with `cksum` to derive a versioned state filename:
   `~/.cache/sshp/connection-v1_<crc>_<size>.state`. The prefix deliberately
   prevents an old destination-only cache entry from being reused after an
   upgrade.
4. If that file's contents match the current signature and `--force` was not
   given, `sshp` runs the login connection and returns.
5. Otherwise it syncs, and only **after** a successful sync writes the new
   signature — atomically, via `mktemp` in the same directory followed by
   `mv -f`. A failed sync leaves the old state intact and will be retried next
   time.

Two different destination strings may therefore share state when `ssh -G`
resolves them to the same effective connection. Conversely, `sshp -p 2222
web01` and `sshp -p 22 web01`, or two `-F` configurations that resolve `web01`
to different endpoints, are tracked independently.

## The transfer

The four files are packed with `tar -czf` into a `mktemp` archive, removed
again by an `EXIT` trap, and streamed on standard input to:

```bash
command ssh -T -o RemoteCommand=none "${ssh_options[@]}" "$target" "$remote_script" < "$archive"
```

- `-T` disables pseudo-terminal allocation for the sync connection.
- `RemoteCommand=none` neutralises a `RemoteCommand` in your SSH config that
  would otherwise swallow the script.
- `ssh_options` holds whatever you passed on the command line. With
  `SSHP_WARN_WEAK_CRYPTO=no`, it is prefixed with `-o WarnWeakCrypto=no` when
  the installed OpenSSH supports that setting.

The login connection is a separate `command ssh "${ssh_options[@]}" "$target"`
call afterwards. This is why the first call after a change opens **two**
connections and prompts twice for a password if you are not using keys or a
control master.

## What the remote script does

Read from the heredoc `REMOTE` in `ssh-prompt.sh`, it runs under `set -eu` and:

1. Verifies that `tar`, `bash`, `grep`, `mktemp`, `touch` and `rm` all exist,
   reporting the missing one by name.
2. Sets `umask 077`.
3. Creates `~/.hushlogin` to suppress post-authentication MOTD/last-login output on subsequent connections. This file does not suppress an sshd pre-authentication `Banner`.
4. Extracts the archive into a temporary sibling under `~/.cache`, never into
   the active `~/.cache/ssh-prompt` tree.
5. Syntax-checks all four files in that staging tree.
6. Publishes the validated tree by renaming the old prompt directory aside and
   moving the staged directory into place. An `EXIT`/signal cleanup restores
   the old tree if activation fails and removes staging/backup leftovers.
7. If `~/.bashrc` does not already contain the start marker
   `# >>> sshp managed prompt >>>`, it backs the file up **once** to
   `~/.bashrc.before-sshp` (only if no backup exists yet), builds the new
   content in a `mktemp` file, appends the guarded loader block, syntax-checks
   the result, `chmod 600`s it, and replaces `~/.bashrc` with `mv -f`.

The appended block only sources the prompt for SSH sessions:

```bash
# >>> sshp managed prompt >>>
if [[ -n ${SSH_CONNECTION-} && -r "$HOME/.cache/ssh-prompt/prompt.sh" ]]; then
    source "$HOME/.cache/ssh-prompt/prompt.sh"
fi
# <<< sshp managed prompt <<<
```

Idempotency comes from the marker check, so repeated syncs only replace the
validated tree under `~/.cache/ssh-prompt` and never append the block twice. A
bad archive or a syntax-invalid prompt therefore cannot partially overwrite the
currently working remote prompt.

## Prerequisites and constraints

| Side | Requirement |
|---|---|
| Local | `cksum`, `tar`, `gzip`, `mktemp`, OpenSSH client with `ssh -G` configuration expansion |
| Remote | `bash`, `tar`, `grep`, `mktemp`, `touch`, `rm`; GNU `ls` for correct `ll` output |
| Remote | A writable `$HOME`, and a `~/.bashrc` that is actually read on login |

Hosts whose login shell is not Bash, or where `~/.bashrc` is not sourced for
interactive SSH sessions, will accept the sync but not show the prompt.

## Troubleshooting

**"sshp: `<path>` is missing or not readable."**
One of the three sync files is missing from the checkout. Check
`BASH_CONFIG_ROOT` and that you did not delete or move anything.

**"sshp: cksum is missing on the local system."**
No `cksum` in `PATH`. Install GNU coreutils.

**"sshp: `<tool>` is missing on the destination."**
The remote host lacks one of the six required tools. Either install it or use
`command ssh` for that host.

**"sshp: sync or .bashrc update failed."**
The sync connection failed or the remote script errored out. Nothing was saved
locally, so the next attempt will retry. Reproduce the sync connection by hand
to see the real error:

```bash
command ssh -T -o RemoteCommand=none HOST 'echo ok; command -v tar grep mktemp touch'
```

**Every login syncs again.**
The state file could not be written. Check that `~/.cache/sshp` is writable, and
that `HOME` is set to what you expect.

**Prompt does not appear even though the sync succeeded.**
Confirm on the remote host:

```bash
grep -n 'sshp managed prompt' ~/.bashrc
ls -l ~/.cache/ssh-prompt/prompt.sh
```

If both are fine, the login shell probably is not Bash, or `~/.bashrc` is not
read for interactive SSH shells (some distributions gate it behind
`~/.bash_profile`).

**Two password prompts on the first login after a change.**
Expected — sync and login are separate connections. Use SSH keys, or enable an
`ssh_config` control master to reuse the connection:

```
Host *
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60
```

**Force a clean re-sync**

```bash
sshp --force HOST          # ignore the stored signature
rm -rf ~/.cache/sshp       # forget every target's state
```
