#!/usr/bin/env bash

# Shared invocation layer for ssh and sshp.
# By default connections are started with -q. --banner or --no-quiet turns the
# quiet output off for a single call. SSH_TOOLS_QUIET=0 turns the default off
# for the whole shell.
#
# Pre-existing ssh/sshp functions or aliases are saved on first load and are
# then called by the wrappers below.

# Options whose argument may follow as a separate word. This is only needed so
# --banner is recognised after options such as "-p 22" without accidentally
# changing remote command arguments.
__ssh_tools_option_takes_arg() {
    case $1 in
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-P|-p|-Q|-R|-S|-W|-w)
            return 0
            ;;
    esac
    return 1
}

# Save the original commands only once. That makes re-sourcing ssh-tools.sh in
# the same shell harmless.
if [[ -z ${__ssh_tools_transport_captured+x} ]]; then
    declare -gA __ssh_tools_original_kind=()
    declare -gA __ssh_tools_original_alias=()
    declare -gA __ssh_tools_original_path=()

    __ssh_tools_capture_original() {
        local name=$1 kind definition path private_name

        path=$(type -P "$name" 2>/dev/null || true)
        [[ -z $path ]] || __ssh_tools_original_path["$name"]=$path

        if [[ -n ${BASH_ALIASES["$name"]+x} ]]; then
            __ssh_tools_original_kind["$name"]='alias'
            __ssh_tools_original_alias["$name"]=${BASH_ALIASES["$name"]}
            return 0
        fi

        kind=$(type -t "$name" 2>/dev/null || true)
        case $kind in
            function)
                definition=$(declare -f "$name") || return 1
                private_name="__ssh_tools_original_${name}"
                # "declare -f" starts with the function name. Replace only
                # that name; the function body stays unchanged.
                eval "$private_name${definition#"$name"}"
                __ssh_tools_original_kind["$name"]='function'
                ;;
            file|builtin)
                __ssh_tools_original_kind["$name"]=$kind
                ;;
            *)
                __ssh_tools_original_kind["$name"]='none'
                ;;
        esac
    }

    __ssh_tools_capture_original ssh
    __ssh_tools_capture_original sshp

    # The aliases have to go so the wrapper functions of the same name are not
    # expanded before function resolution during interactive input.
    unalias ssh sshp 2>/dev/null || true
    unset -f ssh sshp 2>/dev/null || true

    __ssh_tools_transport_captured=1
fi

# Call the external command directly. This also guards against recursion if a
# saved alias itself starts with "ssh ...", for example.
__ssh_tools_invoke_base() {
    local name=$1
    shift
    local path=${__ssh_tools_original_path["$name"]-}

    if [[ -n $path ]]; then
        "$path" "$@"
        return $?
    fi

    printf '%s: no external base command found.\n' "$name" >&2
    return 127
}

__ssh_tools_invoke_original() {
    local name=$1
    shift
    local kind=${__ssh_tools_original_kind["$name"]-none}
    local command_line arg rc private_name
    local __SSH_TOOLS_WRAPPER_BYPASS=1

    case $kind in
        function)
            private_name="__ssh_tools_original_${name}"
            "$private_name" "$@"
            ;;
        alias)
            command_line=${__ssh_tools_original_alias["$name"]}
            for arg in "$@"; do
                printf -v command_line '%s %q' "$command_line" "$arg"
            done
            eval "$command_line"
            rc=$?
            return "$rc"
            ;;
        file|builtin)
            __ssh_tools_invoke_base "$name" "$@"
            ;;
        *)
            printf '%s: available neither as the original command, a function nor an alias.\n' \
                "$name" >&2
            return 127
            ;;
    esac
}

# Prepares the arguments and removes only our own switches ahead of the SSH
# destination. Remote command arguments stay unchanged.
declare -a __ssh_tools_transport_args=()
__ssh_tools_transport_quiet=1

__ssh_tools_prepare_transport_args() {
    local arg option expect_arg=0 options_done=0 destination_seen=0
    local quiet=${SSH_TOOLS_QUIET:-1}

    __ssh_tools_transport_args=()

    for arg in "$@"; do
        if (( destination_seen )); then
            __ssh_tools_transport_args+=("$arg")
            continue
        fi

        if (( expect_arg )); then
            __ssh_tools_transport_args+=("$arg")
            expect_arg=0
            continue
        fi

        if (( ! options_done )); then
            case $arg in
                --banner|--no-quiet)
                    quiet=0
                    continue
                    ;;
                --quiet)
                    quiet=1
                    continue
                    ;;
                --)
                    __ssh_tools_transport_args+=("$arg")
                    options_done=1
                    continue
                    ;;
                -* )
                    __ssh_tools_transport_args+=("$arg")
                    option=${arg:0:2}
                    if __ssh_tools_option_takes_arg "$option" && [[ ${#arg} -eq 2 ]]; then
                        expect_arg=1
                    fi
                    continue
                    ;;
            esac
        fi

        destination_seen=1
        __ssh_tools_transport_args+=("$arg")
    done

    case ${quiet,,} in
        0|false|no|off) __ssh_tools_transport_quiet=0 ;;
        *)              __ssh_tools_transport_quiet=1 ;;
    esac
}

ssh() {
    # An already saved alias or function body may itself call "ssh" again. In
    # that case, pass straight through to the external OpenSSH command.
    if [[ ${__SSH_TOOLS_WRAPPER_BYPASS:-0} == 1 ]]; then
        __ssh_tools_invoke_base ssh "$@"
        return $?
    fi

    __ssh_tools_prepare_transport_args "$@"

    if (( __ssh_tools_transport_quiet )); then
        __ssh_tools_invoke_original ssh -q "${__ssh_tools_transport_args[@]}"
    else
        __ssh_tools_invoke_original ssh "${__ssh_tools_transport_args[@]}"
    fi
}

sshp() {
    if [[ ${__SSH_TOOLS_WRAPPER_BYPASS:-0} == 1 ]]; then
        # On a recursive call there is not necessarily an external base
        # command for sshp. Use it if there is one.
        __ssh_tools_invoke_base sshp "$@"
        return $?
    fi

    __ssh_tools_prepare_transport_args "$@"

    # Bypassing during the original sshp call prevents a second -q in case its
    # function or alias internally calls the new ssh wrapper.
    local __SSH_TOOLS_WRAPPER_BYPASS=1
    if (( __ssh_tools_transport_quiet )); then
        __ssh_tools_invoke_original sshp -q "${__ssh_tools_transport_args[@]}"
    else
        __ssh_tools_invoke_original sshp "${__ssh_tools_transport_args[@]}"
    fi
}
