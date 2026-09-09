# SSH tools

`bashrc.d/ssh-tools.sh` is the entry point for the SSH helpers. It sources six
library files and six completion files, registers aliases, and wires up Bash
completion. It is safe to re-source in the same shell.

## Commands at a glance

| Command | Alias for | Purpose |
|---|---|---|
| `known-hosts`, `ssh-known-hosts` | `ssh_known_hosts` | Readable, numbered overview of all known SSH targets |
| `known-hosts-clean`, `ssh-known-hosts-clean` | `ssh_known_hosts_clean` | Verify host keys, remove stale entries and config aliases |
| `ssh-nr` | `ssh_by_number` | Log in by target number from the `known-hosts` list |
| `ssh-resolve-ips` | `ssh_resolve_ips` | Reverse-DNS for every IP in the config and `known_hosts` |
| `ssh-resolve-hosts` | `ssh_resolve_hosts` | Forward-DNS for every hostname in the config and `known_hosts` |
| `bash-commands`, `bashrc-help` | `bash_config_commands` | List every command this configuration provides |

Both a hyphenated and a second alias exist for most of these so they are easy
to find by tab completion. The underlying function names are also completable.

---

## `bash-commands`

```
bash-commands [--details] [FILTER]
bash-commands --check
bash-commands --help
```

The discoverability entry point: it lists every command the configuration adds
to your shell, grouped by purpose, so you do not have to read `docs/` to
remember what exists.

```
Prompt und Anzeige
  ll                  Verzeichnisinhalt mit ausgerichteten Spalten und farbigem Besitzer

SSH-Verbindung
  ssh                 OpenSSH-Wrapper; einfache Logins laufen ueber sshp
  sshp                Prompt-Dateien zum Ziel uebertragen und einloggen
  ssh-nr              Login ueber die Zielnummer aus known-hosts

SSH-Uebersicht
  known-hosts         Bekannte SSH-Ziele mit Alias, Benutzer und Zielnummer
  ssh-resolve-ips     IPs aus SSH-Config und known_hosts per Reverse-DNS aufloesen
...
```

| Option | Effect |
|---|---|
| `--details`, `-d` | Add the call syntax, the synonym and the defining file under each command |
| `--check` | Print a verification table instead of the list |
| `--help`, `-h` | Usage |
| `FILTER` | A single case-insensitive substring, matched against name, synonym and description |

`--check` cannot be combined with `FILTER` or `--details`, and more than one
free-form argument is rejected; both return exit code `2`. A filter that matches
nothing prints a short note and returns `0`.

A command that is listed but not defined in the current shell is flagged in red
with `(nicht definiert)`.

### Why `--check` exists

The command table is hand-maintained in `bashrc.d/commands.sh`, because what a
command *does* cannot be derived from the code. That invites drift: rename an
alias and the listing quietly lies. `--check` resolves every listed name and
synonym with `alias` and `type -t`, prints its kind (`Funktion`, `Alias`,
`Builtin`, `Programm`) and its defining file, and returns exit code `1` if
anything is missing:

```
BEFEHL                   ART         QUELLE
ll                       Funktion    bashrc.d/listing.sh
ssh                      Funktion    ssh-prompt.sh
known-hosts              Alias       bashrc.d/lib/known-hosts.sh
  ssh-known-hosts        Alias       Synonym
...
Alle aufgefuehrten Befehle sind definiert.
```

So it works as a cheap self-test after any refactor:

```bash
bash-commands --check || echo 'Tabelle in bashrc.d/commands.sh veraltet'
```

Note that it only catches one direction. A command that exists but is missing
*from* the table cannot be detected this way — adding an entry stays a manual
step.

---

## `known-hosts`

```
known-hosts [--lines] [--refresh] [FILTER]
known-hosts --fingerprints
known-hosts --help
```

Prints one row per **target**, where a target is a unique combination of config
alias, `known_hosts` lookup key and effective user. Multiple `known_hosts` lines
and multiple key types for the same target are merged into a single row.

```
NR  ZIEL                  ALIAS         BENUTZER  SCHLÜSSEL
1   web01.example.com     web01         deploy    ED25519, RSA
2   10.0.0.9              -             alex      ED25519
3   [db.example.com]:2222 db-prod       postgres  ED25519
4   [gehashter Hostname]  -             -         ED25519
```

| Column | Meaning |
|---|---|
| `NR` | Stable target number for the current file state — this is what `ssh-nr` takes |
| `ZEILE` | `known_hosts` line numbers, comma-separated (only with `--lines`) |
| `ZIEL` | The lookup key: hostname, `[host]:port`, or a marker such as `@cert-authority` |
| `ALIAS` | Matching `~/.ssh/config` alias, or `-` if the entry has none |
| `BENUTZER` | Effective SSH user, or `-` if none could be determined |
| `SCHLÜSSEL` | Key types, normalised (leading `ssh-` stripped, uppercased) |

### Options

| Option | Effect |
|---|---|
| `--lines`, `--zeilen` | Add the `ZEILE` column with `known_hosts` line numbers |
| `--refresh` | Discard the in-shell caches and re-read everything |
| `--fingerprints` | Run `ssh-keygen -l -E sha256` once over the whole file and print its original output |
| `--help`, `-h` | Usage |
| `FILTER` | A single case-insensitive substring |
| `--` | Ends option parsing; at most one `FILTER` may follow |

`--fingerprints` cannot be combined with `FILTER`, `--lines` or `--refresh`; the
combination returns exit code `2`. More than one free-form argument is also
rejected with `2`.

### Filtering

The filter is matched case-insensitively against the concatenation of number,
alias, target, user, key types and line numbers, so all of these work:

```bash
known-hosts prod        # alias or hostname substring
known-hosts deploy      # by user
known-hosts ed25519     # by key type
known-hosts 2222        # by port in the lookup key
```

When nothing matches, the header is still printed followed by
`Keine lesbaren Einträge für "<filter>" gefunden.`

### Colour semantics

`ZIEL` and `ALIAS` are cyan, key types are yellow, and the user column is
**magenta when the user is inherited** rather than explicitly configured. A
plain (uncoloured) user means it comes from a concrete `Host` block in your own
config. A magenta user was inherited from a `Host *` block, a wildcard pattern
or the OpenSSH default. This is a useful hint that a target may not be using the
account you think it is.

### Hashed entries

If `HashKnownHosts` is enabled, the original hostname cannot be recovered from
the file. Such lines are shown as `[gehashter Hostname]`, and they are never
displayed as if they were a readable hostname. They are also excluded from
filtering by name, for the same reason.

### Performance and processes

The default view and the filter start **no external processes at all** for
rendering — the parsing is done in pure Bash. What does run:

- `ssh -G -T` once per concrete config alias, to resolve `HostName`, `User`,
  `Port` and `HostKeyAlias`. This opens no network connection, but it *does*
  evaluate `Match exec` rules if you have any.
- `ssh-keygen -F` once per alias, to find the matching `known_hosts` lines.
- Exactly one `ssh-keygen -l -E sha256` for `--fingerprints`.

Results are cached in the shell. The cache is keyed by the
`known_hosts`/config pair and additionally holds a copy of the `known_hosts`
contents, so editing that file invalidates the cache automatically.
`--refresh` clears the `known-hosts` cache, the completion cache and the
`ssh-resolve-ips` DNS cache in one go.

---

## `ssh-nr`

```
ssh-nr NR [SSH-OPTIONEN ...]
ssh-nr --list
ssh-nr --help
```

Connects to the target with the given `NR` from the `known-hosts` list. The
grouping is rebuilt from the same model, so numbers always agree between the two
commands for a given file state.

```bash
known-hosts        # look at the list
ssh-nr 3           # connect to target 3
ssh-nr --list      # same as plain known-hosts
```

Resolution rules:

- **If the target has a config alias**, `ssh-nr` connects via the alias. That is
  deliberate: `User`, `Port`, `ProxyJump`, `IdentityFile` and everything else
  from `~/.ssh/config` then apply exactly as configured.
- **Otherwise** the raw `known_hosts` target is used. `[host]:port` is split
  into host and `-p port`.
- Markers (`@cert-authority`, `@revoked`), hashed entries, comma-separated host
  lists and wildcard patterns are **not** connectable and are rejected with a
  clear message.

The connection itself always goes through `sshp`, so a target reached by number
gets the same prompt sync as a direct `sshp` call.
`__ssh_by_number_run_sshp` deals with `sshp` being a function, an external
command, a builtin or an alias — in the alias case it rebuilds the command line
with `printf %q` and `eval` so arguments stay shell-safe.

Numbers must be positive integers; an invalid or out-of-range number returns a
message pointing you back at `known-hosts`.

Any options you add are inserted **before** the destination, next to the ones
`ssh-nr` supplies itself: `-F "$SSH_CONFIG_FILE"` when a non-default config is
in use, and `-p <port>` for an alias-less target on a non-standard port.

```bash
ssh-nr 2 -v                    # verbose, port and config still applied
SSH_CONFIG_FILE=~/.ssh/config.customer ssh-nr 1
```

Since `sshp` forwards options to both its connections, the sync and the login
use identical settings. A remote command is not possible here — `sshp` rejects
anything after the destination; use `command ssh` for that.

---

## `known-hosts-clean`

```
known-hosts-clean            # dry run (default)
known-hosts-clean --apply    # write changes, after creating backups
known-hosts-clean --help
```

Checks each usable `known_hosts` entry against the host's live key with
`ssh-keyscan`, and then removes matching stale aliases from your primary SSH
config. **Nothing is written without `--apply`.**

### `known_hosts` pass

For each line:

| Situation | Action |
|---|---|
| Comment or blank | Kept verbatim |
| Marker line (`@cert-authority`, …) | `SKIP marker entry`, kept — and the target counts as "keep", which protects its config alias |
| Hashed (`\|1\|…`) | `SKIP hashed entry`, kept |
| Complex host field (`,` `*` `?` `!`) | `SKIP complex host`, kept |
| Exact duplicate of an already-kept line | `DUPLICATE -> REMOVE` |
| Live key matches stored key | `OK`, kept |
| Live key differs | `KEY MISMATCH -> REMOVE` |
| No key returned / host unreachable | `UNREACHABLE -> REMOVE` |
| Key type not supported by the scanner | `UNSUPPORTED KEY TYPE -> KEEP` |

Supported key types for scanning are `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-*`,
`ssh-ed25519-sk` and `ecdsa-sk-*`. Duplicate detection uses the tuple
(marker, host field, key type, key), so differing whitespace or trailing
comments do not hide a duplicate. Incomplete lines are kept unchanged.

### SSH config pass

A target is only considered **stale** if at least one of its entries was
`KEY MISMATCH` or `UNREACHABLE` **and** no entry for that same target was kept.
That two-sided rule prevents a host with one obsolete key and one valid key from
being removed.

Then, for each concrete `Host` alias in the primary config:

1. Resolve it with `ssh -G` the same way `known-hosts` does, yielding
   `HostName`, `Port` and the `known_hosts` lookup key.
2. If the lookup key is stale → remove the alias.
3. If the lookup key was checked and is not stale → keep the alias.
4. If there is no checkable `known_hosts` entry (never connected, or only a
   hashed entry) → probe `HostName`/`Port` directly with `ssh-keyscan`. Any
   returned host key counts as reachable; an unreachable endpoint is removed.
   Endpoint results are cached per host/port.

Safety rules for rewriting the config:

- Complex `Host` lines — wildcards, `?`, `!`, `[`, quotes, whitespace — are
  reported as `CONFIG SKIP complex Host line` and never modified.
- An alias that `ssh -G` cannot evaluate is kept.
- If **all** concrete aliases of a `Host` line drop out, the whole block is
  removed up to the next `Host`/`Match` line, so commented-out block options
  such as `#IdentityFile` are not left orphaned.
- If only some aliases drop out, the `Host` line is rewritten with the remaining
  tokens, preserving the original indentation and any trailing comment.
- **`Include` files are never modified.** Only the primary config is rewritten.

### Backups and rollback

With `--apply` and at least one change, a timestamped backup is created next to
each file that is about to change:

```
~/.ssh/known_hosts.bak.20260909-141530
~/.ssh/config.bak.20260909-141530
```

Files without changes are neither backed up nor rewritten. If a write fails, the
backups are copied back. On success the `known-hosts` and completion caches are
invalidated so the next command sees the new state.

Before doing anything, `--apply` verifies that both files are writable, and the
command as a whole requires `ssh-keyscan`, `ssh` and `awk` to be present.

### Environment

| Variable | Default | Purpose |
|---|---|---|
| `SSH_KNOWN_HOSTS_FILE` | `~/.ssh/known_hosts` | File to clean |
| `SSH_CONFIG_FILE` | `~/.ssh/config` | Primary config to clean |
| `SSH_KNOWN_HOSTS_CLEAN_TIMEOUT` | `3` | `ssh-keyscan` timeout in seconds |

### Warning

"Unreachable" and "obsolete" are indistinguishable from the outside. Running
`--apply` while off the VPN, behind a firewall, or with a host temporarily down
will delete perfectly valid entries. Always read the dry run first, and consider
raising the timeout on slow links:

```bash
SSH_KNOWN_HOSTS_CLEAN_TIMEOUT=10 known-hosts-clean
```

---

## `ssh-resolve-ips`

```
ssh-resolve-ips [FILTER]
ssh-resolve-ips --refresh
ssh-resolve-ips --help
```

Collects every IP literal referenced by your SSH setup and reverse-resolves it.

```
IP           HOSTNAME              CONFIG              KNOWN_HOSTS
10.0.0.9     db01.example.com      db-prod, db-stage   4,17
192.168.1.5  -                     ~/.ssh/hosts.d:12   -
```

| Column | Contents |
|---|---|
| `IP` | Each IP appears exactly once |
| `HOSTNAME` | PTR record, or `-` if the lookup failed |
| `CONFIG` | Aliases referencing it, or `file:line` when no concrete alias applies; `-` if none |
| `KNOWN_HOSTS` | Line numbers in `known_hosts`, or `-` |

Where the IPs come from:

- The resolved `HostName` of each concrete config alias, via `ssh -G`. This also
  catches IPs that come from a more general `Host` pattern.
- Raw IP literals in `Host` and `HostName` lines, including files pulled in via
  `Include`. Config paths are displayed with `~/` shortened.
- The host field of every non-hashed `known_hosts` line, split on commas.

Both plain IPs and `[IP]:port` are recognised, for IPv4 and IPv6. The system
`/etc/ssh/ssh_config` is deliberately **not** scanned here, since it is not part
of your personal inventory.

### Reverse-DNS backends

The first available backend that returns an answer wins:

1. `getent hosts`
2. `dig +short -x`
3. `host`
4. `powershell.exe` with `System.Net.Dns.GetHostEntry` — the most reliable
   option under Git Bash on Windows, because it prints only the hostname
5. `nslookup`

Each is wrapped in `timeout <n>s` when `timeout` is available. Results are
cached per shell, including negative results, so repeated calls are fast.
`--refresh` clears the DNS cache; `known_hosts` and the SSH config are re-read
on every call regardless.

| Variable | Default | Purpose |
|---|---|---|
| `SSH_RESOLVE_IP_TIMEOUT` | `3` | Per-lookup timeout in seconds; must be a positive integer |

The filter is a single case-insensitive substring matched against IP, hostname,
config references and line numbers. Passing more than one argument returns exit
code `2`.

---

## `ssh-resolve-hosts`

```
ssh-resolve-hosts [FILTER]
ssh-resolve-hosts --refresh
ssh-resolve-hosts --help
```

The mirror image of `ssh-resolve-ips`: that one starts from IP literals and asks
DNS for names, this one starts from hostnames and asks DNS for addresses.
Together they cover both halves of your SSH inventory.

```
HOSTNAME                IP                     CONFIG   KNOWN_HOSTS
web01.example.com       10.0.0.5, 2001:db8::5  web01    1
multi.example.com       10.0.0.7, 10.0.0.8     db-prod  2
plain-only.example.com  -                      -        3
```

| Column | Contents |
|---|---|
| `HOSTNAME` | Each name appears exactly once |
| `IP` | All addresses, IPv4 first, comma-separated; `-` if the lookup failed |
| `CONFIG` | Aliases referencing it, or `file:line` when no concrete alias applies; `-` if none |
| `KNOWN_HOSTS` | Line numbers in `known_hosts`, or `-` |

Where the names come from mirrors `ssh-resolve-ips` exactly:

- the resolved `HostName` of each concrete config alias, via `ssh -G`, so names
  inherited from a broader `Host` pattern are included;
- raw `Host` and `HostName` values in the user config and its `Include` files,
  with paths displayed as `~/…`;
- the host field of every non-hashed `known_hosts` line, split on commas.

`[host]:port` is unwrapped, and the system `/etc/ssh/ssh_config` is deliberately
not scanned. IP literals are skipped here — they belong to `ssh-resolve-ips` —
as are wildcard patterns, markers and hashed entries, none of which can be
resolved.

### Forward-DNS backends

The first available backend that answers wins:

1. `getent ahosts` — returns one line per address *family*, so duplicates are
   collapsed
2. `dig +short NAME A` and `AAAA`
3. `host` — the `has address` / `has IPv6 address` lines
4. `powershell.exe` with `System.Net.Dns.GetHostAddresses` for Git Bash on
   Windows
5. `nslookup`

Every candidate line is validated as an IPv4 or IPv6 literal before it is shown,
which is what makes the `dig` path safe: `dig +short` prints intermediate CNAME
targets alongside the addresses, and those are dropped rather than displayed as
an address.

Results are cached per shell, negative answers included, so repeated calls are
free. `--refresh` clears the cache, and so does `known-hosts --refresh`.
`known_hosts` and the config are re-read on every call regardless.

| Variable | Default | Purpose |
|---|---|---|
| `SSH_RESOLVE_HOST_TIMEOUT` | `3` | Per-lookup timeout in seconds; must be a positive integer |

The filter is a single case-insensitive substring matched against name,
addresses, config references and line numbers. More than one argument returns
exit code `2`.

> This file reuses the IP predicates, the timeout wrapper and the path shortener
> from `lib/ssh-resolve-ips.sh` instead of duplicating them, so `ssh-tools.sh`
> must source it after that file. The function checks the dependency at runtime
> and reports it rather than failing obscurely.

---

## Tab completion

Completion is registered for the aliases, the hyphenated names **and** the
underlying function names.

### `ssh` and `sshp`

`_ssh_tools_ssh_completion` handles both. It does something unusual and worth
knowing about: instead of using `COMP_WORDS`, it parses `COMP_LINE` up to
`COMP_POINT` itself, honouring single quotes, double quotes and backslash
escapes. The reason is `@`, which is part of the default `COMP_WORDBREAKS` and
would otherwise split `user@host` before the completion function ever sees it.
This way `COMP_WORDBREAKS` is left untouched but `user@host` is treated as one
logical argument.

What it completes:

- **Only at the destination position.** Options and their arguments are skipped;
  once a destination has been given, nothing more is offered.
- **Filenames** after `-F`, `-i`, `-E`, `-I` and `-S`.
- **`--force` and `--help`** for both `ssh` and `sshp`. The two commands share
  one argument parser, so both really accept these switches.
- **Config aliases** and **plain `known_hosts` hostnames**. Entries such as
  `[host]:2222`, wildcard patterns and marker lines are excluded, because they
  are not valid `ssh` destinations.
- **`user@alias` targets**, resolved once per cache refresh. This makes
  completion work from either side:

  ```
  ssh web<TAB>      ->  web01
  ssh depl<TAB>     ->  deploy@web01
  ssh deploy@<TAB>  ->  deploy@web01, deploy@web02
  ```

  When the typed user matches a configured alias, only matching aliases are
  offered; otherwise it falls back to all hosts so an explicit user override
  still completes. Whether the reply carries the full `user@` prefix or just
  `@host` depends on whether `@` is in your `COMP_WORDBREAKS` — both cases are
  handled.

### The shared host cache

`bashrc.d/completions/ssh-hosts.bash` holds one lazy cache used by every
completion. It is built on the first `TAB` and keeps two lists:

- **filter hosts** — everything, including `[host]:port` and patterns, used by
  the `known-hosts` filter completion;
- **connect hosts** — only valid `ssh` destinations, plus resolved `user@alias`
  targets.

Invalidation compares stored contents against current contents for the user
config, `/etc/ssh/ssh_config` and every `Include`d file, and re-runs each
`Include` glob through `compgen -G` so that added or removed files are noticed
too. `known_hosts` is watched the same way. All of this uses Bash builtins, so
pressing `TAB` does not fork processes just to validate the cache.

### The other completions

| Command | Completes |
|---|---|
| `known-hosts` | `--lines`, `--zeilen`, `--refresh`, `--fingerprints`, `--help`; one filter from the filter-host list. Nothing after `--fingerprints`, and nothing once a filter is present |
| `known-hosts-clean` | `--apply`, `--help` at the first position only |
| `ssh-nr` | The valid target numbers `1..n` at the first position; also `--help` and `--list` |
| `ssh-resolve-ips` | `--refresh`, `--help` at the first position only |
| `ssh-resolve-hosts` | `--refresh`, `--help` at the first position only |
| `bash-commands` | `--details`, `--check`, `--help`; one filter from the list of command names. Nothing after `--check` |

`ssh-nr` completion builds the same grouping as `known-hosts`, so the offered
numbers are always the real ones.
