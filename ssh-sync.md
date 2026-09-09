# `sshp` — prompt sync and login

`sshp` is defined in `ssh-prompt.sh`. It pushes the prompt files to a remote
host and then opens an interactive login. When nothing has changed since the
last sync to that host, it skips straight to the login, so the common case costs
exactly one SSH connection.

## Usage

```bash
sshp HOST                 # SSH config alias
sshp user@host            # explicit user
sshp --force HOST         # re-sync even if the signature matches
```

Exactly one destination is required. Anything else — zero arguments, several
arguments, or a destination starting with `-` — prints a usage line and returns
exit code `2`:

```
Aufruf: sshp [--force] user@host oder SSH-Config-Alias
```

> `sshp` does **not** accept OpenSSH options such as `-p` or `-F`. If you need
> them, use `command ssh` directly. This also limits `ssh-nr` for some targets —
> see [architecture.md#known-limitations](architecture.md#known-limitations).

The whole function body is a subshell (`sshp() ( … )`), so its `local`
variables, `trap` and working state cannot leak into your interactive shell.

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
command ssh -T -o RemoteCommand=none -o WarnWeakCrypto=no "$target" "$remote_script" < "$archive"
```

- `-T` disables pseudo-terminal allocation for the sync connection.
- `RemoteCommand=none` neutralises a `RemoteCommand` in your SSH config that
  would otherwise swallow the script.
- `WarnWeakCrypto=no` suppresses the weak-crypto warning (also passed on the
  login connection).

The login connection is a separate, plain `command ssh` call afterwards. This is
why the first call after a change opens **two** connections and prompts twice
for a password if you are not using keys or a control master.

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
