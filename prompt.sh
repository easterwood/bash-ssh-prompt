# SSH-Prompt, angepasst an deine .bashrc. KEIN bash-git-prompt notwendig.
# Nur auf dem Ziel laden; lokal laedt der Installer lediglich ssh-prompt.sh.
# Die Windows-Pfade und die lokale History-Konfiguration werden NICHT kopiert.

[[ $- == *i* ]] || return 0

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'ssh-prompt: Bash 4 oder neuer wird benoetigt.\n' >&2
    return 1
fi

# Dieser Prompt uebernimmt die Prompt-Hooks nur in der aktuellen Sitzung.
trap - DEBUG

# Einstellungen: direkt hier aendern, dann beim naechsten sshp uebertragen.
: "${SSH_PROMPT_SHOW_COMMAND:=1}"  # Letzten Befehl auch im Prompt anzeigen.
: "${SSH_PROMPT_COMMAND_MAX:=0}"   # 0 = keine Kuerzung der Prompt-Befehlszeile.
: "${SSH_PROMPT_MIN_US:=100000}"   # Erfolgreiche Befehle erst ab 100 ms.
: "${SSH_PROMPT_COLOR:=auto}"      # auto, always oder 0.
: "${SSH_PROMPT_SET_TITLE:=auto}"  # auto, 1 oder 0. Titel mit Argumenten.

# ---------------------------------------------------------------------------
# Zeitmessung in Mikrosekunden, wie in deiner lokalen Konfiguration.
# ---------------------------------------------------------------------------

__sshp_init_clock() {
    local stamp
    __sshp_clock=seconds
    if [[ -n ${EPOCHREALTIME-} ]]; then
        __sshp_clock=epoch
    else
        # GNU date ist ein Fallback fuer Bash 4. BSD date kann %N nicht immer.
        stamp=$(command date +%s%6N 2>/dev/null) || stamp=
        if [[ $stamp =~ ^[0-9]{12,18}$ ]]; then
            __sshp_clock=date
        fi
    fi
    return 0
}

__sshp_now() {
    local t sec usec
    case $__sshp_clock in
        epoch)
            t=${EPOCHREALTIME-}
            t=${t/,/.}
            sec=${t%%.*}
            usec=${t#*.}
            usec=${usec}000000
            usec=${usec:0:6}
            if [[ $sec =~ ^[0-9]+$ && $usec =~ ^[0-9]{6}$ ]]; then
                __sshp_now_us=$((10#$sec * 1000000 + 10#$usec))
                return 0
            fi
            ;;
        date)
            t=$(command date +%s%6N 2>/dev/null) || t=
            if [[ $t =~ ^[0-9]{12,18}$ ]]; then
                __sshp_now_us=$((10#$t))
                return 0
            fi
            ;;
    esac
    # Letzter Fallback: grobe Sekundenaufloesung, ohne weitere Abhaengigkeit.
    __sshp_clock=seconds
    __sshp_now_us=$((SECONDS * 1000000))
    return 0
}

__sshp_format_duration() {
    local elapsed_us=$1 total_s
    (( elapsed_us >= 0 )) || elapsed_us=0
    if [[ $__sshp_clock == seconds ]]; then
        if (( elapsed_us < 1000000 )); then
            __sshp_duration='<1s (grob)'
        else
            printf -v __sshp_duration '~%ds' "$((elapsed_us / 1000000))"
        fi
    elif (( elapsed_us < 1000 )); then
        __sshp_duration='<1ms'
    elif (( elapsed_us < 1000000 )); then
        printf -v __sshp_duration '%dms' "$(((elapsed_us + 500) / 1000))"
    else
        total_s=$((elapsed_us / 1000000))
        if (( total_s < 60 )); then
            printf -v __sshp_duration '%d.%03ds' \
                "$total_s" "$(((elapsed_us / 1000) % 1000))"
        elif (( total_s < 3600 )); then
            printf -v __sshp_duration '%dm%02ds' \
                "$((total_s / 60))" "$((total_s % 60))"
        else
            printf -v __sshp_duration '%dh%02dm%02ds' \
                "$((total_s / 3600))" "$(((total_s / 60) % 60))" \
                "$((total_s % 60))"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Vollstaendige eingegebene Befehlszeile, einschliesslich Argumenten.
# ---------------------------------------------------------------------------

__sshp_history_entry() {
    local entry
    __sshp_history_id=
    __sshp_history_text=
    [[ -o history ]] || return 0
    entry=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1 2>/dev/null) || return 0
    if [[ $entry =~ ^[[:space:]]*([0-9]+)\*?[[:blank:]]+(.*)$ ]]; then
        __sshp_history_id=${BASH_REMATCH[1]}
        __sshp_history_text=${BASH_REMATCH[2]}
        __sshp_history_text=${__sshp_history_text#"${__sshp_history_text%%[![:space:]]*}"}
        __sshp_history_text=${__sshp_history_text%"${__sshp_history_text##*[![:space:]]}"}
    fi
    return 0
}

__sshp_sanitize() {
    __sshp_safe_text=$1
    __sshp_safe_text=${__sshp_safe_text//$'\n'/ ; }
    __sshp_safe_text=${__sshp_safe_text//[[:cntrl:]]/ }
    return 0
}

# ---------------------------------------------------------------------------
# Fenstertitel: Befehl mit Argumenten zuerst, Verzeichnis zuletzt.
# UTF-8-Trennzeichen als Bytes, damit die Skriptdatei selbst ASCII bleibt.
# ---------------------------------------------------------------------------

__sshp_set_window_title() {
    local cmd=${__sshp_last_command-} dir
    [[ -n $cmd && -t 2 ]] || return 0
    case ${SSH_PROMPT_SET_TITLE:-auto} in
        1|yes|always) ;;
        auto)
            case ${TERM:-dumb} in
                xterm*|rxvt*|screen*|tmux*|alacritty*|foot*|wezterm*|st-*) ;;
                *) return 0 ;;
            esac
            ;;
        *) return 0 ;;
    esac
    __sshp_sanitize "$cmd"
    cmd=$__sshp_safe_text
    if [[ $PWD == "$HOME" ]]; then
        dir='~'
    elif [[ $PWD == / ]]; then
        dir='/'
    else
        dir=${PWD##*/}
    fi
    __sshp_sanitize "$dir"
    printf '\033]0;%s \342\200\224 %s\007' "$cmd" "$__sshp_safe_text" >&2
    return 0
}

__sshp_before_command() {
    # Nur der erste Befehl einer Eingabe startet den Timer.
    [[ ${__sshp_waiting:-0} == 1 ]] || return 0
    # Bei functrace auch interne Schritte unserer Funktionen ignorieren.
    [[ ${FUNCNAME[1]-} != __sshp_* ]] || return 0
    case $1 in
        __sshp_before_prompt*) return 0 ;;
    esac
    __sshp_waiting=0
    __sshp_history_entry
    if [[ -n $__sshp_history_id &&
          $__sshp_history_id != "${__sshp_previous_history_id-}" ]]; then
        __sshp_last_command=$__sshp_history_text
    else
        # Keine alte Zeile und keine durch ignorespace ausgeblendeten Daten
        # anzeigen. Bei ignorierter History ist die volle Eingabe unbekannt.
        __sshp_last_command='(nicht in der History)'
    fi
    __sshp_set_window_title
    __sshp_now
    __sshp_started_us=$__sshp_now_us
    __sshp_started_clock=$__sshp_clock
    __sshp_running=1
    return 0
}

# Genau EINE Arm-Funktion: Titel nach Programmende wiederherstellen.
__sshp_arm() {
    __sshp_set_window_title
    __sshp_waiting=1
    trap '__sshp_before_command "$BASH_COMMAND"' DEBUG
    return 0
}

# ---------------------------------------------------------------------------
# Prompt: deine Statusregeln, aber ohne prompt_callback/Git-Plugin.
# ---------------------------------------------------------------------------

__sshp_build_prompt() {
    local use_color=0 min_us limit
    case ${SSH_PROMPT_COLOR:-auto} in
        1|yes|always) use_color=1 ;;
        auto)
            if [[ ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
                use_color=1
            fi
            ;;
    esac

    min_us=${SSH_PROMPT_MIN_US:-100000}
    [[ $min_us =~ ^[0-9]{1,9}$ ]] || min_us=100000
    min_us=$((10#$min_us))
    __sshp_status=
    if (( __sshp_last_exit != 0 )); then
        __sshp_status=$'\342\234\227 '"$__sshp_last_exit"
        if [[ -n $__sshp_duration ]]; then
            __sshp_status+=$' \302\267 '"$__sshp_duration"
        fi
    elif [[ -n $__sshp_duration ]] && (( __sshp_elapsed_us >= min_us )); then
        __sshp_status=$__sshp_duration
    fi

    __sshp_sanitize "${__sshp_last_command-}"
    __sshp_display_command=$__sshp_safe_text
    limit=${SSH_PROMPT_COMMAND_MAX:-0}
    if [[ $limit =~ ^[0-9]{1,6}$ ]]; then
        limit=$((10#$limit))
        if (( limit > 0 && ${#__sshp_display_command} > limit )); then
            __sshp_display_command=${__sshp_display_command:0:limit}' ...'
        fi
    fi

    # Verzeichnis als Daten einsetzen, nicht als ausfuehrbaren PS1-Text.
    case $PWD in
        "$HOME") __sshp_display_path='~' ;;
        "$HOME"/*) __sshp_display_path="~${PWD#"$HOME"}" ;;
        *) __sshp_display_path=$PWD ;;
    esac
    __sshp_sanitize "$__sshp_display_path"
    __sshp_display_path=$__sshp_safe_text

    PS1='\n'
    if [[ ${SSH_PROMPT_SHOW_COMMAND:-1} == 1 && -n $__sshp_display_command ]]; then
        (( ! use_color )) || PS1+='\[\e[90m\]'
        PS1+='letzter: ${__sshp_display_command}'
        (( ! use_color )) || PS1+='\[\e[0m\]'
        PS1+='\n'
    fi
    (( ! use_color )) || PS1+='\[\e[36m\]'
    PS1+='\u@\h'
    (( ! use_color )) || PS1+='\[\e[0m\]'
    PS1+=': '
    (( ! use_color )) || PS1+='\[\e[34m\]'
    PS1+='${__sshp_display_path}'
    (( ! use_color )) || PS1+='\[\e[0m\]'
    if [[ -n $__sshp_status ]]; then
        PS1+='  '
        if (( use_color )); then
            if (( __sshp_last_exit != 0 )); then
                PS1+='\[\e[31m\]'
            else
                PS1+='\[\e[32m\]'
            fi
        fi
        PS1+='${__sshp_status}'
        (( ! use_color )) || PS1+='\[\e[0m\]'
    fi
    PS1+='\n[\D{%d.%m.%Y %H:%M:%S}] \$ '
    return 0
}

__sshp_before_prompt() {
    # Status als Argument erhalten, BEVOR irgendeine Prompt-Aktion laeuft.
    local rc=$1 elapsed_us
    __sshp_waiting=0
    trap - DEBUG
    if [[ ${__sshp_running:-0} == 1 ]]; then
        __sshp_now
        elapsed_us=$((__sshp_now_us - __sshp_started_us))
        (( elapsed_us >= 0 )) || elapsed_us=0
        __sshp_elapsed_us=$elapsed_us
        __sshp_last_exit=$rc
        if [[ $__sshp_clock == "$__sshp_started_clock" ]]; then
            __sshp_format_duration "$elapsed_us"
        else
            __sshp_duration='?'
        fi
        __sshp_running=0
        __sshp_history_entry
    else
        __sshp_history_entry
        # Syntaxfehler, reine Subshells und Definitionen koennen den Timer
        # umgehen. Trotzdem neuen Text und Status erfassen, ohne Dauer.
        # Leeres ENTER nach einem Fehler darf dagegen nichts ueberschreiben.
        if [[ $rc != "$__sshp_last_exit" ||
              $__sshp_history_id != "${__sshp_previous_history_id-}" ]]; then
            __sshp_last_exit=$rc
            __sshp_duration=
            __sshp_elapsed_us=0
            if [[ -n $__sshp_history_id &&
                  $__sshp_history_id != "${__sshp_previous_history_id-}" ]]; then
                __sshp_last_command=$__sshp_history_text
            elif (( rc != 0 )); then
                __sshp_last_command='(Abbruch oder Fehler vor Befehlsstart)'
            else
                __sshp_last_command='(nicht in der History)'
            fi
        fi
    fi
    __sshp_previous_history_id=$__sshp_history_id
    __sshp_build_prompt
    __sshp_arm
    return "$rc"
}

# Bestehende Prompt-Systeme nicht parallel ausfuehren.
# Server-.bashrc und sonstige Dateien werden dadurch NICHT geaendert.
unset PROMPT_COMMAND
PROMPT_COMMAND='__sshp_before_prompt "$?"'
PS0=
PS2='> '
shopt -s promptvars
__sshp_waiting=0
__sshp_running=0
__sshp_last_exit=0
__sshp_elapsed_us=0
__sshp_duration=
__sshp_last_command=
__sshp_previous_history_id=
__sshp_init_clock
__sshp_history_entry
__sshp_previous_history_id=$__sshp_history_id
trap '__sshp_before_command "$BASH_COMMAND"' DEBUG
