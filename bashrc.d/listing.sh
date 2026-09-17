#!/usr/bin/env bash

export TIME_STYLE='+%Y-%m-%d %H:%M:%S'

# The user name cannot change within a shell session, so it is resolved once at
# load time. It used to be ${USER:-$(id -un)} inside ll(). Git Bash leaves USER
# empty and sets USERNAME instead, so the fallback fired on every single call:
# the fork alone cost 26 ms, id itself another 17 ms.
__listing_user=${USER:-${LOGNAME:-${USERNAME:-}}}
[[ -n $__listing_user ]] || __listing_user=$(id -un 2>/dev/null) || __listing_user=''
__listing_user=${__listing_user%%@*}

unalias ll 2>/dev/null
ll() {
    command ls \
        -oah \
        --color=always \
        --group-directories-first \
        --time-style='+%Y-%m-%d %H:%M:%S' \
        "$@" |
    awk -v current_user="$__listing_user" '
        BEGIN {
            reset   = "\033[0m"
            dim     = "\033[2m"
            cyan    = "\033[36m"
            magenta = "\033[35m"
            red     = "\033[31m"
            blue    = "\033[34m"
            yellow  = "\033[33m"

            printf "%s%-11s %-4s %-20s %10s %-19s %s%s\n",
                dim, "PERMS", "LINK", "USER", "SIZE",
                "MODIFIED", "NAME", reset
        }

        # The ls summary line is localized: "total" in C and English locales,
        # "insgesamt" in German ones. It is also the only line with exactly two
        # fields, so both spellings are dropped without touching real entries.
        NF == 2 && ($1 == "total" || $1 == "insgesamt") { next }

        {
            user = $3
            sub(/@.*/, "", user)

            if (user == "root") {
                user_color = red
            } else if (user == current_user) {
                user_color = cyan
            } else {
                user_color = magenta
            }

            name = $7
            for (i = 8; i <= NF; i++) name = name " " $i

            printf "%s%-11s%s %-4s %s%-20s%s %s%10s%s %s%-10s %-8s%s %s\n",
                dim, $1, reset, $2, user_color, user, reset,
                yellow, $4, reset, blue, $5, $6, reset, name
        }
    '
}
