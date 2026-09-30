#!/usr/bin/env bash

# prompt-core.sh provides __prompt_command_is_array, which this file uses when
# hooking into PROMPT_COMMAND. bashrc.sh sources it first; say so out loud
# rather than failing with "command not found" halfway through.
declare -F __prompt_command_is_array >/dev/null || {
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
# duplicated in ~/.bash_history and come back at the next start. This rewrites
# the file so that every command appears exactly once, at the position of its
# most recent use, with that use's timestamp.
#
# Multi-line entries and entries without a "#<epoch>" line are preserved.
# Called without an argument on purpose: the default is $HISTFILE.
# shellcheck disable=SC2119,SC2120
history_dedupe() {
    local target=${1:-$HISTFILE} temporary

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
        mv -f -- "$temporary" "$target" || rm -f -- "$temporary"
    else
        rm -f -- "$temporary"
    fi
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
    local repeated=0

    (( HISTCMD == __history_previous_histcmd )) && repeated=1
    __history_previous_histcmd=$HISTCMD

    history -a
    if (( repeated && HISTORY_DEDUPE_LIVE )); then
        history_dedupe
    fi
    return 0
}

# prompt-core.sh is sourced before this file and provides
# __prompt_command_is_array, which replaces the forking
# $(declare -p PROMPT_COMMAND) test.
# PROMPT_COMMAND is an array from Bash 5.1 on and a string before that.
# Both forms are handled deliberately.
# shellcheck disable=SC2178,SC2179
if __prompt_command_is_array; then
    PROMPT_COMMAND+=(__history_append)
else
    PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND%;};}__history_append"
fi
