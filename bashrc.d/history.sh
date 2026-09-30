#!/usr/bin/env bash

# prompt-core.sh owns PROMPT_COMMAND composition. bashrc.sh sources it first;
# say so out loud rather than failing with "command not found" halfway through.
declare -F __prompt_command_append >/dev/null || {
    printf 'history.sh: bashrc.d/prompt-core.sh has to be sourced first.\n' >&2
    return 1
}

HISTFILE="$HOME/.bash_history"
HISTSIZE=1000000
HISTFILESIZE=200000
HISTTIMEFORMAT='%F %T '

# Rewrite the history file whenever a repeated command is entered.
#
# This used to default to 1 and is the most expensive thing in the whole
# prompt path: history_dedupe forks four times (mktemp, awk, chmod, mv) and
# runs awk over the complete history file, which HISTFILESIZE allows to grow
# to 200000 lines. Under MSYS2 that is easily half a second, and it happens
# exactly when a command is repeated -- which is most of the time.
#
# With 0 the file is still cleaned at every shell start, so nothing is lost;
# the duplicates just survive until the next start. Set it to 1 in local.sh if
# you want the old behaviour back.
HISTORY_DEDUPE_LIVE=${HISTORY_DEDUPE_LIVE:-0}

# Clean the file once at shell start. Set to 0 to make the shell start faster
# and clean up manually with "history_dedupe" instead.
HISTORY_DEDUPE_ON_START=${HISTORY_DEDUPE_ON_START:-1}

# erasedups: a repeated command drops its earlier occurrences and is kept
# only at the end of the history. Add ":ignorespace" to also skip commands
# that start with a space.
HISTCONTROL=erasedups:ignorespace
export HISTFILE HISTSIZE HISTFILESIZE HISTTIMEFORMAT HISTCONTROL

# Never overwrite the file another session already wrote to.
shopt -s histappend
# Keep a multi-line command as a single history entry.
shopt -s cmdhist

# HISTCONTROL only ever touches the history list of the running shell, never
# the file on disk. Entries written by earlier sessions therefore stay
# duplicated in ~/.bash_history and come back at the next start. Rewriting the
# shared file has to be serialized with every history -a writer: otherwise a
# second shell can append to the old inode between our read and the final mv.
#
# The lock uses Bash noclobber for atomic creation, so the uncontended acquire
# itself does not fork. Releasing it needs one rm. A dead owner is recovered by
# PID after contention; the random token prevents a shell from removing a lock
# that has already been replaced by another owner.
__history_lock_token=''
__history_lock_warned=0

__history_lock_try() {
    local lock=$1 token=$2 status had_noclobber=0

    [[ $- == *C* ]] && had_noclobber=1
    set -C
    { printf '%s\n' "$token" > "$lock"; } 2>/dev/null
    status=$?
    (( had_noclobber )) || set +C
    return "$status"
}

__history_lock_acquire() {
    local target=$1 lock owner='' owner_pid='' current=''
    local pid=${BASHPID:-$$} token attempt

    lock="${target}.lock"

    token="${pid}:${RANDOM}:${SECONDS}"

    for ((attempt=0; attempt<100; attempt++)); do
        if __history_lock_try "$lock" "$token"; then
            REPLY=$lock
            __history_lock_token=$token
            return 0
        fi

        owner=''
        [[ ! -r $lock ]] || IFS= read -r owner < "$lock" || owner=''
        owner_pid=${owner%%:*}

        # An interrupted PROMPT_COMMAND can leave this shell's own lock behind
        # while the process itself stays alive. There is no nested acquisition
        # in the implementation, so a lock carrying our PID is safe to reclaim.
        if [[ $owner_pid == "$pid" ]]; then
            current=''
            [[ ! -r $lock ]] || IFS= read -r current < "$lock" || current=''
            if [[ $current == "$owner" ]]; then
                command rm -f -- "$lock" 2>/dev/null || true
                continue
            fi
        fi

        # Other stale locks are uncommon (normally SIGKILL/power loss). Only
        # recover one when its recorded owner definitely no longer exists.
        if [[ $owner_pid =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
            # Re-read before unlinking so a lock replaced while we inspected it
            # is not removed by the stale-owner path.
            current=''
            [[ ! -r $lock ]] || IFS= read -r current < "$lock" || current=''
            if [[ $current == "$owner" ]]; then
                command rm -f -- "$lock" 2>/dev/null || true
                continue
            fi
        fi

        # Only contended paths sleep/fork; the normal history append does not.
        sleep 0.05
    done

    return 1
}

__history_lock_release() {
    local lock=$1 token=$2 owner=''

    [[ ! -r $lock ]] || IFS= read -r owner < "$lock" || owner=''
    [[ $owner == "$token" ]] || return 1
    command rm -f -- "$lock"
}

# The rewrite body assumes the caller owns the history lock. Keeping it
# separate avoids a nested lock when __history_append detects a repeat.
__history_dedupe_locked() {
    local target=$1 temporary

    [[ -n $target && -s $target && -w $target ]] || return 0
    command -v awk >/dev/null 2>&1 || return 0

    temporary=$(mktemp -- "$target.XXXXXX") || return 0

    if awk '
        function flush() {
            if (!started || !has_cmd) { started = 0; return }
            if (cmd in last) delete keep[last[cmd]]
            n++
            stamp[n] = ts
            line[n] = cmd
            last[cmd] = n
            keep[n] = 1
            started = 0
        }
        /^#[0-9]+$/ {
            flush()
            ts = $0; cmd = ""; has_cmd = 0; started = 1
            next
        }
        {
            if (started && ts != "") {
                cmd = has_cmd ? cmd "\n" $0 : $0
                has_cmd = 1
            } else {
                flush()
                ts = ""; cmd = $0; has_cmd = 1; started = 1
            }
        }
        END {
            flush()
            for (i = 1; i <= n; i++) {
                if (!(i in keep)) continue
                if (stamp[i] != "") print stamp[i]
                print line[i]
            }
        }
    ' "$target" > "$temporary" && [[ -s $temporary ]]; then
        chmod --reference="$target" -- "$temporary" 2>/dev/null || chmod 600 -- "$temporary"
        mv -f -- "$temporary" "$target" || {
            rm -f -- "$temporary"
            return 1
        }
    else
        rm -f -- "$temporary"
    fi
}

# Multi-line entries and entries without a "#<epoch>" line are preserved.
# Called without an argument on purpose: the default is $HISTFILE.
# shellcheck disable=SC2119,SC2120
history_dedupe() {
    local target=${1:-$HISTFILE} lock token status=0

    [[ -n $target && -s $target && -w $target ]] || return 0
    command -v awk >/dev/null 2>&1 || return 0

    if ! __history_lock_acquire "$target"; then
        if (( ! __history_lock_warned )); then
            printf 'history: could not acquire lock for %s; skipping deduplication.\n' \
                "$target" >&2
            __history_lock_warned=1
        fi
        return 0
    fi

    lock=$REPLY
    token=$__history_lock_token
    __history_dedupe_locked "$target" || status=$?
    __history_lock_release "$lock" "$token" || status=1
    return "$status"
}

# Bash reads the history file only after the startup files have run, so
# cleaning it up here means the shell starts with the deduplicated list.
(( HISTORY_DEDUPE_ON_START )) && history_dedupe

# Bash only saves the history when the shell exits cleanly. A Windows reboot,
# a killed terminal or a crashed session therefore loses everything typed
# since the shell started. Appending after every command closes that gap.
#
# erasedups drops the earlier occurrence from the history list of this shell,
# but "history -a" has already written it to the file, so the file would keep
# the duplicate until the next shell start. HISTCMD does not advance when
# erasedups removes an entry, which is a free signal that the command just
# entered was a repeat. Only then is the file rewritten.
#
__history_previous_histcmd=$HISTCMD

__history_append() {
    local repeated=0 lock token status=0

    (( HISTCMD == __history_previous_histcmd )) && repeated=1
    __history_previous_histcmd=$HISTCMD

    if __history_lock_acquire "$HISTFILE"; then
        lock=$REPLY
        token=$__history_lock_token

        history -a || status=$?
        if (( repeated && HISTORY_DEDUPE_LIVE )); then
            __history_dedupe_locked "$HISTFILE" || status=$?
        fi

        __history_lock_release "$lock" "$token" || status=1
        return "$status"
    fi

    # A wedged live owner should not block the prompt forever. The lock waits
    # up to five seconds; after that defer the flush. Bash keeps unappended
    # entries in memory, so the next successful history -a writes them all. Do
    # not write without the lock: that would reintroduce the inode-replacement
    # race this protocol exists to prevent.
    if (( ! __history_lock_warned )); then
        printf 'history: could not acquire lock for %s; deferring history flush.\n' \
            "$HISTFILE" >&2
        __history_lock_warned=1
    fi
    return 0
}

# prompt-core.sh owns the string/array details and appends without replacing
# hooks installed by anything sourced earlier.
__prompt_command_append __history_append
