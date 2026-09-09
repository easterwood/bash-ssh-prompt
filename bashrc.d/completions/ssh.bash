#!/usr/bin/env bash

# Options whose next word is an argument. This is used only to determine
# whether the current argument is the SSH destination.
__ssh_completion_option_takes_arg() {
    case $1 in
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-P|-p|-Q|-R|-S|-W|-w)
            return 0
            ;;
    esac
    return 1
}

# Parse the command line up to COMP_POINT without evaluating it. Unlike
# COMP_WORDS, this keeps characters from COMP_WORDBREAKS (notably '@') in the
# logical argument. Basic shell quoting and backslash escaping are honored.
declare -a __ssh_completion_line_words=()
__ssh_completion_line_cword=0

__ssh_completion_parse_line() {
    local input=${COMP_LINE:0:COMP_POINT}
    local token='' state=plain char
    local have_token=0 i

    __ssh_completion_line_words=()
    __ssh_completion_line_cword=0

    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}

        case $state in
            plain)
                case $char in
                    ' '|$'\t'|$'\n')
                        if (( have_token )); then
                            __ssh_completion_line_words+=("$token")
                            token=''
                            have_token=0
                        fi
                        ;;
                    "'")
                        state=single
                        have_token=1
                        ;;
                    '"')
                        state=double
                        have_token=1
                        ;;
                    '\\')
                        state=escape
                        have_token=1
                        ;;
                    *)
                        token+=$char
                        have_token=1
                        ;;
                esac
                ;;
            single)
                if [[ $char == "'" ]]; then
                    state=plain
                else
                    token+=$char
                fi
                ;;
            double)
                case $char in
                    '"') state=plain ;;
                    '\\') state=double_escape ;;
                    *) token+=$char ;;
                esac
                ;;
            escape)
                token+=$char
                state=plain
                ;;
            double_escape)
                token+=$char
                state=double
                ;;
        esac
    done

    if (( have_token )); then
        __ssh_completion_line_words+=("$token")
    else
        # Cursor after whitespace: the argument being completed is empty.
        __ssh_completion_line_words+=('')
    fi

    __ssh_completion_line_cword=$((${#__ssh_completion_line_words[@]} - 1))
}

__ssh_completion_is_destination_position() {
    local i word expect_arg=0 options_done=0

    # Inspect only complete logical arguments before the one at the cursor.
    for ((i=1; i<__ssh_completion_line_cword; i++)); do
        word=${__ssh_completion_line_words[i]}

        if (( expect_arg )); then
            expect_arg=0
            continue
        fi

        if (( options_done )); then
            # A destination was already supplied before the current argument.
            return 1
        fi

        if [[ $word == -- ]]; then
            options_done=1
            continue
        fi

        if [[ $word == -* && $word != - ]]; then
            # Argument attached to the option, for example -p2222 or -luser.
            if __ssh_completion_option_takes_arg "${word:0:2}"; then
                [[ ${#word} -gt 2 ]] || expect_arg=1
            fi
            continue
        fi

        # First non-option argument is the destination.
        return 1
    done

    (( ! expect_arg ))
}

__ssh_completion_file_argument() {
    local cur=${__ssh_completion_line_words[__ssh_completion_line_cword]-}
    local prev=''

    (( __ssh_completion_line_cword > 0 )) && \
        prev=${__ssh_completion_line_words[__ssh_completion_line_cword-1]}

    case $prev in
        -F|-i|-E|-I|-S)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
    esac

    return 1
}

_ssh_tools_ssh_completion() {
    local known_hosts_file=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
    local config=${SSH_CONFIG_FILE:-$HOME/.ssh/config}
    local cur host target user_prefix host_part reply_prefix key
    local have_user_match=0
    local sep=$'\x1f'

    COMPREPLY=()

    # COMP_WORDS is intentionally not used for destination parsing here.
    # '@' is normally part of COMP_WORDBREAKS, so Bash splits user@host before
    # invoking a completion function. COMP_LINE/COMP_POINT retain the original
    # text and let us reconstruct the logical argument without changing the
    # global COMP_WORDBREAKS setting.
    __ssh_completion_parse_line

    # Keep filename completion for common file-valued SSH options.
    __ssh_completion_file_argument && return 0

    __ssh_completion_is_destination_position || return 0

    cur=${__ssh_completion_line_words[__ssh_completion_line_cword]-}

    # Eigene Long-Switches. ssh und sshp nehmen dieselben Argumente an, deshalb
    # werden sie fuer beide Kommandos angeboten.
    if [[ $cur == --* ]]; then
        [[ --force == "$cur"* ]] && COMPREPLY+=(--force)
        [[ --help == "$cur"* ]] && COMPREPLY+=(--help)
        return 0
    fi

    __ssh_completion_cache_ensure "$known_hosts_file" "$config" || return 0

    if [[ $cur != *@* ]]; then
        # Normal host completion plus resolved user@alias targets. This allows
        # completion to start from either side, for example:
        #   ssh test<TAB>
        #   ssh oster<TAB>  -> osterwald@test-alias
        for host in "${__ssh_completion_connect_hosts[@]}"; do
            [[ $host == "$cur"* ]] || continue
            COMPREPLY+=("$host")
        done

        for target in "${__ssh_completion_connect_targets[@]}"; do
            [[ $target == "$cur"* ]] || continue
            COMPREPLY+=("$target")
        done

        return 0
    fi

    user_prefix=${cur%@*}
    host_part=${cur##*@}

    if [[ $COMP_WORDBREAKS == *@* ]]; then
        # With '@' as a Bash word break, Readline replaces the text from '@'
        # onward. Returning '@host' preserves the separator and leaves the
        # already typed user name untouched.
        reply_prefix='@'
    else
        # Respect a user's custom COMP_WORDBREAKS without changing it. In this
        # case Readline replaces the complete user@host argument.
        reply_prefix="$user_prefix@"
    fi

    # If the typed user is known from the SSH config, prefer aliases that
    # resolve to that user. This makes "user@<TAB>" useful as a user-based
    # lookup. If there is no matching configured alias, fall back to all hosts
    # so an explicit user override still works.
    for host in "${__ssh_completion_connect_hosts[@]}"; do
        [[ $host == "$host_part"* ]] || continue
        key="$user_prefix$sep$host"
        [[ -n ${__ssh_completion_user_host["$key"]+x} ]] || continue
        COMPREPLY+=("$reply_prefix$host")
        have_user_match=1
    done

    if (( ! have_user_match )); then
        for host in "${__ssh_completion_connect_hosts[@]}"; do
            [[ $host == "$host_part"* ]] || continue
            COMPREPLY+=("$reply_prefix$host")
        done
    fi

    return 0
}
