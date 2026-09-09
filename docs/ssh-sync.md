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

Errors all return exit code `2` with a usage block:

| Situation | Message |
|---|---|
| No destination given | `sshp: Es wird genau ein SSH-Ziel benoetigt.` |
| An option's argument is missing (e.g. a trailing `-p`) | `sshp: Zur letzten Option fehlt das Argument.` |
| Words remain after the destination | `sshp: Ein Remote-Kommando wird nicht unterstuetzt: …` |

A remote command is rejected on purpose: `sshp` always ends in an interactive
login, so `sshp host uname -a` would sync the prompt for nothing. Use
`command ssh host uname -a` instead.

The whole function body is a subshell (`sshp() ( … )`), so its `local`
variables, `trap` and working state cannot leak into your interactive shell.

## Option pass-through

Options are collected into one array that is used for **both** the sync
connection and the login connection, so `-p`, `-F`, `-J`, `-i` and friends apply
consistently — a target on a non-standard port syncs over that same port.

`sshp`'s own options are placed first:

```
sync:   ssh -T -o RemoteCommand=none -o WarnWeakCrypto=no <your options> HOST
login:  ssh -o WarnWeakCrypto=no <your options> HOST
```

The order matters. For `-o` settings OpenSSH keeps the **first** value it sees,
so `RemoteCommand=none` cannot be overridden by a `RemoteCommand` in your
config, while your own `-o` settings still win over anything the config file
supplies later.

`__sshp_option_takes_arg` knows which OpenSSH options consume the following
word (`-B -b -c -D -E -e -F -I -i -J -L -l -m -O -o -P -p -Q -R -S -W -w`), so
both `-p 2222` and the attached form `-p2222` are parsed correctly and the
destination is never mistaken for an option argument.

> The stored sync state is keyed by the **destination string only**, not by the
> options. `sshp web01` and `sshp -F other-config web01` therefore share one
> state entry. If two configs map the same alias to different machines, force a
> re-sync with `--force`.

## The `ssh()` wrapper

`ssh-prompt.sh` also redefines `ssh`:

```bash
ssh() {
    if (( $# == 1 )) && [[ -n ${1-} && ${1-} != -* ]]; then
        sshp "$1"
    else
        command ssh "$@"
    fi
}
```

So a bare `ssh myserver` gets the synced prompt, while anything with options or
a remote command goes to the real OpenSSH client untouched:

| Command | Path taken |
|---|---|
| `ssh server` | `sshp server` |
| `ssh -p 2222 server` | native `ssh` |
| `ssh server uname -a` | native `ssh` |
| `command ssh server` | native `ssh` |

The wrapper is deliberately conservative and was left alone when `sshp` gained
option pass-through: `sshp -p 2222 server` now works, but `ssh -p 2222 server`
still goes straight to OpenSSH, so tunnels (`-N -L …`) and one-off commands
behave exactly as they always did. Call `sshp` explicitly when you want the
synced prompt with options.

`ssh-prompt.sh` runs `unalias ssh sshp` before defining the two functions,
because aliases are expanded before function lookup and a distribution-supplied
`alias ssh=…` would otherwise shadow them.

## Which files are synced

```
prompt.sh
bashrc.d/listing.sh
bashrc.d/prompt-core.sh
```

Before anything is transferred, each file must exist, be readable, and pass
`bash -n`. A syntax error aborts the whole call — you never push a broken prompt
to a server.

## How change detection works

1. A **signature** is computed locally: the literal format tag
   `sshp-sync-format=4`, then for each file its relative path and its `cksum`
   output, all piped through `cksum` again. Bumping the format tag in a future
   version therefore invalidates every stored state at once.
2. The destination string is hashed with `cksum` to derive a state filename:
   `~/.cache/sshp/<crc>_<size>.state`.
3. If that file's contents match the current signature and `--force` was not
   given, `sshp` runs the login connection and returns.
4. Otherwise it syncs, and only **after** a successful sync writes the new
   signature — atomically, via `mktemp` in the same directory followed by
   `mv -f`. A failed sync leaves the old state intact and will be retried next
   time.

Because the state is keyed by the destination string, `sshp web01` and
`sshp user@web01.example.com` are tracked as two separate targets even if they
resolve to the same machine.

## The transfer

The three files are packed with `tar -czf` into a `mktemp` archive, removed
again by an `EXIT` trap, and streamed on standard input to:

```bash
command ssh -T -o RemoteCommand=none "${ssh_options[@]}" "$target" "$remote_script" < "$archive"
```

- `-T` disables pseudo-terminal allocation for the sync connection.
- `RemoteCommand=none` neutralises a `RemoteCommand` in your SSH config that
  would otherwise swallow the script.
- `ssh_options` starts with `-o WarnWeakCrypto=no` and then holds whatever you
  passed on the command line.

The login connection is a separate `command ssh "${ssh_options[@]}" "$target"`
call afterwards. This is why the first call after a change opens **two**
connections and prompts twice for a password if you are not using keys or a
control master.

## What the remote script does

Read from the heredoc `REMOTE` in `ssh-prompt.sh`, it runs under `set -eu` and:

1. Verifies that `tar`, `bash`, `grep`, `mktemp` and `touch` all exist,
   reporting the missing one by name.
2. Sets `umask 077`.
3. Creates `~/.hushlogin` to silence the login banner on subsequent connections.
4. Extracts the archive into `~/.cache/ssh-prompt` with `tar --no-same-owner`.
5. Syntax-checks all three extracted files.
6. If `~/.bashrc` does not already contain the start marker
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
files under `~/.cache/ssh-prompt` and never append the block twice.

## Prerequisites and constraints

| Side | Requirement |
|---|---|
| Local | `cksum`, `tar`, `gzip`, `mktemp`, OpenSSH client |
| Remote | `bash`, `tar`, `grep`, `mktemp`, `touch`; GNU `ls` for correct `ll` output |
| Remote | A writable `$HOME`, and a `~/.bashrc` that is actually read on login |

Hosts whose login shell is not Bash, or where `~/.bashrc` is not sourced for
interactive SSH sessions, will accept the sync but not show the prompt.

## Troubleshooting

**"sshp: `<path>` fehlt oder ist nicht lesbar."**
One of the three sync files is missing from the checkout. Check
`BASH_CONFIG_ROOT` and that you did not delete or move anything.

**"sshp: cksum fehlt auf dem lokalen System."**
No `cksum` in `PATH`. Install GNU coreutils.

**"sshp: `<tool>` fehlt auf dem Ziel."**
The remote host lacks one of the five required tools. Either install it or use
`command ssh` for that host.

**"sshp: Synchronisierung oder .bashrc-Aktualisierung fehlgeschlagen."**
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
