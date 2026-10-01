#!/usr/bin/env bash

# `filter` is the caller's local, reached through Bash's dynamic scoping, so
# ShellCheck sees it assigned here without a declaration. That is the point of
# these helpers; see the comment below.
# shellcheck disable=SC2154

# Shared conventions for the listing commands' option parsing.
#
# known-hosts and bash-commands both take "[OPTIONS] [FILTER]" with at most one
# positional FILTER, and both honour a "--" separator before it. That handling
# was written out twice, down to the wording of the error message, in three
# places per command. One of them drifting is a question of when, not whether.
#
# The helpers assign the caller's `filter` local, the same dynamic-scoping
# arrangement __ssh_resolve_table uses for its spec. The caller declares
# `local filter=''` and passes its own user-visible name as COMMAND so the
# error says "known-hosts:" or "bash-commands:" accordingly.

# __opt_filter_set COMMAND VALUE
#
# Takes the one positional filter. Returns 2 when there already is one.
__opt_filter_set() {
    [[ -z $filter ]] || {
        printf '%s: only one FILTER is allowed.\n' "$1" >&2
        return 2
    }

    filter=$2
}

# __opt_filter_separator COMMAND REMAINING...
#
# The "--" branch: at most one word may follow the separator, and that word is
# the filter. REMAINING is the caller's argument list after "--" was shifted
# off. __opt_filter_consumed reports how many words were taken, so the caller
# knows whether to shift once more.
__opt_filter_consumed=0

__opt_filter_separator() {
    local command=$1
    shift

    __opt_filter_consumed=0

    (($# <= 1)) || {
        printf '%s: only one FILTER is allowed.\n' "$command" >&2
        return 2
    }
    (($#)) || return 0

    __opt_filter_set "$command" "$1" || return 2
    __opt_filter_consumed=1
}
