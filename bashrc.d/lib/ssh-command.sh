#!/usr/bin/env bash

# Gemeinsame Aufrufschicht fuer ssh und sshp.
# Standardmaessig werden Verbindungen mit -q gestartet. Mit --banner bzw.
# --no-quiet kann die stille Ausgabe fuer einen einzelnen Aufruf deaktiviert
# werden. SSH_TOOLS_QUIET=0 deaktiviert den Default fuer die gesamte Shell.
#
# Bereits vorhandene ssh-/sshp-Funktionen oder -Aliase werden beim ersten
# Laden gesichert und anschliessend durch die Wrapper unten aufgerufen.

# Optionen, deren Argument als separates Wort folgen kann. Das wird nur
# benoetigt, damit --banner auch nach Optionen wie "-p 22" erkannt wird,
# ohne versehentlich Remote-Kommandoargumente zu veraendern.
__ssh_tools_option_takes_arg() {
    case $1 in
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-P|-p|-Q|-R|-S|-W|-w)
            return 0
            ;;
    esac
    return 1
}

# Originale Befehle nur einmal sichern. Das macht erneutes "source ssh-tools.sh"
# in derselben Shell gefahrlos.
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
                # "declare -f" beginnt mit dem Funktionsnamen. Nur diesen
                # Namen ersetzen; der Funktionskoerper bleibt unveraendert.
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

    # Aliase muessen weg, damit die gleichnamigen Wrapper-Funktionen bei der
    # interaktiven Eingabe nicht vor der Funktionsaufloesung expandiert werden.
    unalias ssh sshp 2>/dev/null || true
    unset -f ssh sshp 2>/dev/null || true

    __ssh_tools_transport_captured=1
fi

# Direkten externen Befehl aufrufen. Wird auch als Rekursionsschutz verwendet,
# falls ein gesicherter Alias z. B. selbst mit "ssh ..." beginnt.
__ssh_tools_invoke_base() {
    local name=$1
    shift
    local path=${__ssh_tools_original_path["$name"]-}

    if [[ -n $path ]]; then
        "$path" "$@"
        return $?
    fi

    printf '%s: kein externer Basisbefehl gefunden.\n' "$name" >&2
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
            printf '%s: weder als urspruenglicher Befehl, Funktion noch Alias verfuegbar.\n' \
                "$name" >&2
            return 127
            ;;
    esac
}

# Bereitet die Argumente vor und entfernt nur unsere eigenen Schalter vor dem
# SSH-Ziel. Argumente des Remote-Kommandos bleiben unveraendert.
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
    # Ein bereits gesicherter Alias/Funktionskoerper kann intern wieder "ssh"
    # aufrufen. In diesem Fall direkt zum externen OpenSSH-Befehl durchreichen.
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
        # Bei einem rekursiven Aufruf gibt es fuer sshp nicht zwingend einen
        # externen Basisbefehl. Falls vorhanden, diesen verwenden.
        __ssh_tools_invoke_base sshp "$@"
        return $?
    fi

    __ssh_tools_prepare_transport_args "$@"

    # Bypass waehrend des Original-sshp-Aufrufs verhindert ein zweites -q,
    # falls dessen Funktion/Alias intern den neuen ssh-Wrapper aufruft.
    local __SSH_TOOLS_WRAPPER_BYPASS=1
    if (( __ssh_tools_transport_quiet )); then
        __ssh_tools_invoke_original sshp -q "${__ssh_tools_transport_args[@]}"
    else
        __ssh_tools_invoke_original sshp "${__ssh_tools_transport_args[@]}"
    fi
}
