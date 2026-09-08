# In der lokalen Git Bash laden:
# source "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh"
# Aufruf: sshp user@host oder sshp SSH-Config-Alias
# Uebertragen werden NUR prompt.sh und die erzeugte Startdatei rc.

sshp() (
    if (( $# != 1 )) || [[ ${1-} == -* || -z ${1-} ]]; then
        printf 'Aufruf: sshp user@host  oder  sshp SSH-Config-Alias\n' >&2
        return 2
    fi

    local target=$1 work tool
    local prompt_file=${PROMPT_SYNC_FILE:-$HOME/.config/bash/ssh-prompt/prompt.sh}

    for tool in ssh bash tar gzip mktemp cp rm; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf 'sshp: %s fehlt lokal.\n' "$tool" >&2
            return 1
        }
    done
    [[ -r $prompt_file ]] || {
        printf 'sshp: Prompt-Datei nicht lesbar: %s\n' "$prompt_file" >&2
        return 1
    }
    bash -n "$prompt_file" || return 1

    work=$(mktemp -d) || return 1
    trap 'rm -rf -- "$work"' EXIT
    # cp -L uebernimmt den Inhalt, auch bei einem lokalen Symlink.
    cp -L -- "$prompt_file" "$work/prompt.sh" || return 1

    cat > "$work/rc" <<'RC' || return 1
# Nur fuer die durch sshp gestartete Bash.
PROMPT_SYNC_HOME="$HOME/.cache/ssh-prompt"
[[ ! -r "$HOME/.bashrc" ]] || source "$HOME/.bashrc"
# Nach .bashrc noch einmal setzen, damit eine dortige Zuweisung nicht stoert.
PROMPT_SYNC_HOME="$HOME/.cache/ssh-prompt"
source "$PROMPT_SYNC_HOME/prompt.sh"
RC

    tar -czf "$work/prompt.tgz" -C "$work" prompt.sh rc || return 1

    # Kein PTY beim Transfer; keine zusaetzlichen Port-Forwardings starten.
    if ! command ssh -T -o RemoteCommand=none -o ClearAllForwardings=yes \
        "$target" '
        set -e
        for c in bash tar gzip; do
            command -v "$c" >/dev/null 2>&1 || {
                printf "sshp: %s fehlt auf dem Ziel.\n" "$c" >&2
                exit 1
            }
        done
        umask 077
        d="$HOME/.cache/ssh-prompt"
        mkdir -p "$d"
        tar --no-same-owner -xzf - -C "$d"
        bash -n "$d/prompt.sh"
        bash -n "$d/rc"
    ' < "$work/prompt.tgz"; then
        printf 'sshp: Synchronisierung fehlgeschlagen; kein Login gestartet.\n' >&2
        return 1
    fi

    command ssh -t -o RemoteCommand=none "$target" \
        'exec bash --rcfile "$HOME/.cache/ssh-prompt/rc" -i'
)
