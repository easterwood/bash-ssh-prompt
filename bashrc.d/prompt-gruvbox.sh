#!/usr/bin/env bash

# Gruvbox Rainbow powerline prompt without starship.
#
# Drop-in replacement for bashrc.d/prompt-local.sh. It reuses the timer from
# prompt-core.sh (__cmd_last_exit, __cmd_duration, __cmd_elapsed_us), so that
# file has to be sourced first.
#
# Design constraint, same as everywhere else in this configuration: a fork
# costs 15-25 ms under MSYS2. The prompt therefore spends
#
#   * one fork per prompt inside a Git repository (a single "git status"),
#   * zero forks outside one,
#   * one fork whenever a toolchain actually changes, not once per shell.
#
# Everything else - the palette, the separators, the ancestor walk, the
# pom.xml and the Docker context - is built from shell builtins.
#
# Caches are keyed on what would invalidate them (JAVA_HOME, PATH, VIRTUAL_ENV)
# rather than on the lifetime of the shell, and the pom.xml is not cached at
# all. Switching a JDK or editing a version is therefore visible in the next
# prompt, without a fork being spent on checking for it.

# bashrc.sh already returns early in a non-interactive shell, so this module
# carries no guard of its own - the same arrangement prompt-local.sh uses. That
# also keeps it sourceable from tests/prompt-gruvbox.sh.

# prompt-core.sh provides the command timer (__cmd_last_exit, __cmd_duration,
# __cmd_elapsed_us) and the shared text helpers this prompt reads. bashrc.sh
# and prompt.sh both source it first; make the requirement explicit rather
# than failing per prompt with "command not found".
declare -F __prompt_command_is_array >/dev/null || {
    printf '%s: bashrc.d/prompt-core.sh has to be sourced first.\n' \
        "${BASH_SOURCE[0]##*/}" >&2
    return 1
}

# --- knobs ------------------------------------------------------------------

# Show the duration from this many microseconds on. The default matches the
# previous prompt_callback behaviour, not starship's two seconds.
: "${PROMPT_GRUVBOX_MIN_DURATION_US:=100000}"

# Set to 0 to drop the Git segment entirely (the only per-prompt fork).
: "${PROMPT_GRUVBOX_GIT:=1}"

# Give up on pom.xml after this many lines. Only a pom with a huge licence
# header ahead of its version element ever reaches this.
: "${PROMPT_GRUVBOX_POM_MAX_LINES:=500}"

# Docker contexts that mean "the one local engine" and are therefore not worth
# a segment. Set to an empty string to always show the context.
: "${PROMPT_GRUVBOX_DOCKER_HIDE:=default desktop-linux desktop-windows}"

# Set to 0 for ASCII separators when a Nerd Font is not available.
: "${PROMPT_GRUVBOX_POWERLINE:=1}"

# Set to 1 to put the clock in front of the input symbol on line three instead
# of into the second powerline line, the way the old Custom theme did it.
: "${PROMPT_GRUVBOX_TIME_ON_INPUT_LINE:=0}"

# Repeat the command that produced the current prompt in the second powerline
# line, between the duration and the exit code. Local and remote shells show it
# alike; prompt.sh seeds this from SSH_PROMPT_SHOW_COMMAND before sourcing, so
# that knob still switches it off over SSH.
: "${PROMPT_GRUVBOX_SHOW_COMMAND:=1}"

# Truncate that repetition to this many characters.
: "${PROMPT_GRUVBOX_COMMAND_MAX_LEN:=60}"

# Show the host name next to the user. Only useful when the shell is not the
# local one, so it follows SSH_CONNECTION by default.
if [[ -z ${PROMPT_GRUVBOX_SHOW_HOST-} ]]; then
    if [[ -n ${SSH_CONNECTION-} ]]; then
        PROMPT_GRUVBOX_SHOW_HOST=1
    else
        PROMPT_GRUVBOX_SHOW_HOST=0
    fi
fi

# Truncate the path to this many components. Bash does this natively.
PROMPT_DIRTRIM=${PROMPT_DIRTRIM:-3}

# --- palette ----------------------------------------------------------------

declare -gA __gb_rgb=(
    [fg0]='251;241;199'
    [bg1]='60;56;54'
    [bg3]='102;92;84'
    [blue]='69;133;136'
    [blue_bright]='131;165;152'
    [aqua]='104;157;106'
    [green]='152;151;26'
    [orange]='214;93;14'
    [purple]='177;98;134'
    [red]='204;36;29'
    [yellow]='215;153;33'
)

declare -gA __gb_fg=() __gb_bg=()
__gb_reset=''
__gb_sep=''
__gb_cap_left=''
__gb_cap_right=''

__gb_init_palette() {
    local esc=$'\e' name

    for name in "${!__gb_rgb[@]}"; do
        __gb_fg[$name]="\[${esc}[38;2;${__gb_rgb[$name]}m\]"
        __gb_bg[$name]="\[${esc}[48;2;${__gb_rgb[$name]}m\]"
    done

    __gb_reset="\[${esc}[0m\]"

    if (( PROMPT_GRUVBOX_POWERLINE )); then
        # U+E0B0 separator, U+E0B6 / U+E0B4 round caps. Written as \u escapes
        # so the file survives an editor with the wrong encoding.
        __gb_sep=$'\ue0b0'
        __gb_cap_left=$'\ue0b6'
        __gb_cap_right=$'\ue0b4'
    else
        __gb_sep=' '
        __gb_cap_left=''
        __gb_cap_right=''
    fi
}
__gb_init_palette

# Glyphs, likewise as escapes. Swap any of them if your Nerd Font build is
# missing a codepoint - "printf '%b\n' '\ue256'" tells you quickly.
__gb_icon_windows=$'\U000f0372'
__gb_icon_linux=$'\U000f033d'
__gb_icon_macos=$'\U000f0035'
__gb_icon_branch=$'\ue0a0'
__gb_icon_detached=$'\ue729'
__gb_icon_java=$'\ue256'
__gb_icon_node=$'\ue718'
__gb_icon_python=$'\ue235'
__gb_icon_package=$'\uf487'
__gb_icon_docker=$'\uf308'
__gb_icon_duration=$'\uf252'
__gb_icon_clock=$'\uf017'
__gb_icon_error=$'\u2718'

case $OSTYPE in
    msys*|cygwin*|win32) __gb_icon_os=$__gb_icon_windows ;;
    darwin*)             __gb_icon_os=$__gb_icon_macos ;;
    *)                   __gb_icon_os=$__gb_icon_linux ;;
esac

# --- helpers ----------------------------------------------------------------

# Quoting and the last-command text come from prompt-core.sh, which both this
# module and prompt-local.sh sit on top of.

# Walk up from $PWD looking for a file or directory. No forks - "[[ -e ]]" is
# a builtin, so this is a handful of stat() calls.
__gb_find_up() {
    local dir=$PWD
    while :; do
        if [[ -e "$dir/$1" ]]; then
            REPLY=$dir
            return 0
        fi
        [[ -n $dir && $dir != / ]] || break
        dir=${dir%/*}
        [[ -n $dir ]] || dir=/
    done
    REPLY=''
    return 1
}

# --- segment engine ---------------------------------------------------------

__gb_ps1=''
__gb_prev_bg=''

__gb_open() {
    __gb_ps1=''
    __gb_prev_bg=''
}

# __gb_add BACKGROUND FOREGROUND TEXT
__gb_add() {
    if [[ -z $__gb_prev_bg ]]; then
        __gb_ps1+="${__gb_fg[$1]}${__gb_cap_left}"
    elif [[ $1 != "$__gb_prev_bg" ]]; then
        __gb_ps1+="${__gb_bg[$1]}${__gb_fg[$__gb_prev_bg]}${__gb_sep}"
    fi
    __gb_ps1+="${__gb_bg[$1]}${__gb_fg[$2]}${3}"
    __gb_prev_bg=$1
}

__gb_close() {
    [[ -n $__gb_prev_bg ]] || return 0
    __gb_ps1+="${__gb_reset}${__gb_fg[$__gb_prev_bg]}${__gb_cap_right}${__gb_reset}"
    __gb_prev_bg=''
}

# --- git --------------------------------------------------------------------

# One "git status" call gives branch, upstream divergence, stash count and all
# file states at once. Parsing happens in the shell, so no second fork.
__gb_git_segment() {
    REPLY=''
    (( PROMPT_GRUVBOX_GIT )) || return 1

    local out line xy ab oid branch='' state=''
    local staged=0 unstaged=0 untracked=0 conflicts=0 ahead=0 behind=0 stash=0

    # Fork-free precondition. Without it every prompt outside a repository
    # still pays for a "git status" that only fails.
    __gb_find_up .git || return 1

    out=$(git status --porcelain=v2 --branch --show-stash 2>/dev/null) || return 1

    while IFS= read -r line; do
        case $line in
            '# branch.head '*) branch=${line#\# branch.head } ;;
            '# branch.oid '*)  oid=${line#\# branch.oid } ;;
            '# branch.ab '*)
                ab=${line#\# branch.ab }
                ahead=${ab%% *}
                ahead=${ahead#+}
                behind=${ab##* }
                behind=${behind#-}
                ;;
            '# stash '*) stash=${line#\# stash } ;;
            '1 '*|'2 '*)
                xy=${line:2:2}
                [[ ${xy:0:1} == . ]] || staged=$(( staged + 1 ))
                [[ ${xy:1:1} == . ]] || unstaged=$(( unstaged + 1 ))
                ;;
            'u '*) conflicts=$(( conflicts + 1 )) ;;
            '? '*) untracked=$(( untracked + 1 )) ;;
        esac
    done <<< "$out"

    if [[ $branch == '(detached)' || -z $branch ]]; then
        branch="${__gb_icon_detached} ${oid:0:7}"
    else
        __prompt_quote "$branch"
        branch="${__gb_icon_branch} ${REPLY}"
    fi

    (( conflicts )) && state+=" =${conflicts}"
    (( staged ))    && state+=" +${staged}"
    (( unstaged ))  && state+=" !${unstaged}"
    (( untracked )) && state+=" ?${untracked}"
    (( stash ))     && state+=" *${stash}"
    (( ahead ))     && state+=$' \u21e1'"${ahead}"
    (( behind ))    && state+=$' \u21e3'"${behind}"

    REPLY="${branch}${state}"
    return 0
}

# --- toolchain versions -----------------------------------------------------

# JAVA_HOME or the PATH almost always carry the version already. Deriving it
# from there is nothing but string operations, so it runs on every prompt and a
# JDK switch is visible in the very next one.
#
# Only when neither carries a number does a JVM have to start, and that result
# is cached against JAVA_HOME and PATH - change either and the cache is gone.
__gb_java_version() {
    local source='' version='' key

    if [[ -n ${JAVA_HOME-} ]]; then
        source=$JAVA_HOME
    elif [[ $PATH =~ [^:]*(jdk|jbr|temurin|zulu|corretto|graalvm|openjdk)[^:]*/bin ]]; then
        source=${BASH_REMATCH[0]}
    fi

    if [[ $source =~ [0-9]+(\.[0-9]+){1,2} ]]; then
        REPLY=${BASH_REMATCH[0]}
        return 0
    fi
    if [[ $source =~ -([0-9]+)- ]]; then
        REPLY=${BASH_REMATCH[1]}
        return 0
    fi

    key="${JAVA_HOME-}|${PATH}"
    if [[ ${__gb_java_key-} == "$key" ]]; then
        REPLY=$__gb_java_cache
        [[ -n $REPLY ]]
        return
    fi

    if command -v java >/dev/null 2>&1; then
        source=$(java -version 2>&1)
        [[ $source =~ version\ \"([0-9][^\"]*)\" ]] && version=${BASH_REMATCH[1]}
    fi

    __gb_java_key=$key
    __gb_java_cache=$version
    REPLY=$version
    [[ -n $version ]]
}

# node --version is a fork, so it stays cached - but against PATH, which is
# what nvm, fnm and volta rewrite when they switch versions.
__gb_node_version() {
    local key=$PATH version=''

    if [[ ${__gb_node_key-} == "$key" ]]; then
        REPLY=$__gb_node_cache
        [[ -n $REPLY ]]
        return
    fi

    if command -v node >/dev/null 2>&1; then
        version=$(node --version 2>/dev/null)
        version=${version#v}
    fi

    __gb_node_key=$key
    __gb_node_cache=$version
    REPLY=$version
    [[ -n $version ]]
}

# Same arrangement, with the active virtualenv in the key.
__gb_python_version() {
    local key="${VIRTUAL_ENV-}|${PATH}" version=''

    if [[ ${__gb_python_key-} == "$key" ]]; then
        REPLY=$__gb_python_cache
        [[ -n $REPLY ]]
        return
    fi

    if command -v python >/dev/null 2>&1; then
        version=$(python --version 2>&1)
        version=${version#Python }
    fi

    __gb_python_key=$key
    __gb_python_cache=$version
    REPLY=$version
    [[ -n $version ]]
}

# The <version> of the project itself, not the one inherited from <parent>.
#
# Read fresh on every prompt, so an edit to pom.xml shows up immediately. That
# is affordable because the reading is a builtin redirect rather than a fork,
# and because the loop stops at the first element that can only follow the
# version: a normal pom costs about 0.05 ms, which is a fortieth of a single
# fork under MSYS2.
#
# The line budget is the guard against the one bad case, a pom that carries a
# few thousand lines of licence header before the version element.
__gb_maven_version() {
    local pom=$1 line in_parent=0 version='' lines=0

    while IFS= read -r line; do
        (( ++lines > PROMPT_GRUVBOX_POM_MAX_LINES )) && break
        case $line in
            *'<parent>'*)  in_parent=1 ;;
            *'</parent>'*) in_parent=0 ;;
            *'<version>'*)
                (( in_parent )) && continue
                line=${line#*<version>}
                version=${line%%</version>*}
                break
                ;;
            *'<properties>'*|*'<modules>'*|*'<dependencyManagement>'*|\
            *'<dependencies>'*|*'<build>'*|*'<profiles>'*)
                break
                ;;
        esac
    done < "$pom"

    version=${version//[[:space:]]/}
    REPLY=$version
    [[ -n $version ]]
}

# --- docker -----------------------------------------------------------------

# Resolved once per shell from the environment or config.json.
#
# The single-engine contexts are hidden, because a badge that always reads the
# same thing carries no information. Under Docker Desktop for Windows that is
# "desktop-linux", so on a stock installation this segment never appears - it
# turns up when you actually point the CLI somewhere else.
__gb_docker_context() {
    if [[ -n ${__gb_docker_cache+x} ]]; then
        REPLY=$__gb_docker_cache
        [[ -n $REPLY ]]
        return
    fi

    local context='' line config profile candidates=()

    if [[ -n ${DOCKER_CONTEXT-} ]]; then
        context=$DOCKER_CONTEXT
    elif [[ -n ${DOCKER_HOST-} ]]; then
        context=${DOCKER_HOST}
    else
        # $HOME under Git Bash is not necessarily %USERPROFILE%, and Docker
        # Desktop writes into the latter. Try both, Windows path separators
        # converted.
        if [[ -n ${DOCKER_CONFIG-} ]]; then
            candidates+=("$DOCKER_CONFIG/config.json")
        else
            candidates+=("$HOME/.docker/config.json")
            if [[ -n ${USERPROFILE-} ]]; then
                profile=${USERPROFILE//\\//}
                candidates+=("$profile/.docker/config.json")
            fi
        fi

        for config in "${candidates[@]}"; do
            [[ -r $config ]] || continue
            while IFS= read -r line; do
                if [[ $line == *'"currentContext"'* ]]; then
                    line=${line#*\"currentContext\"}
                    line=${line#*:}
                    line=${line#*\"}
                    context=${line%%\"*}
                    break
                fi
            done < "$config"
            [[ -z $context ]] || break
        done
    fi

    [[ " $PROMPT_GRUVBOX_DOCKER_HIDE " != *" $context "* ]] || context=''

    __gb_docker_cache=$context
    REPLY=$context
    [[ -n $context ]]
}

# --- the prompt -------------------------------------------------------------

__gb_build() {
    local rc=${__cmd_last_exit:-0}
    local duration=${__cmd_duration-}
    local elapsed=${__cmd_elapsed_us:-0}
    local tail='' symbol symbol_color

    __gb_open

    # 1 - operating system and user, orange. \u and \h are bash prompt escapes,
    #     so neither passes through an expansion of ours.
    if (( PROMPT_GRUVBOX_SHOW_HOST )); then
        __gb_add orange fg0 " ${__gb_icon_os} \\u@\\h "
    else
        __gb_add orange fg0 " ${__gb_icon_os} \\u "
    fi

    # 2 - working directory, yellow. \w is a bash prompt escape, so the path
    #     never passes through an expansion of ours.
    __gb_add yellow fg0 ' \w '

    # 3 - git, aqua.
    if __gb_git_segment; then
        __gb_add aqua fg0 " ${REPLY} "
    fi

    # 4 - toolchain, blue. Only inside a project that actually uses it, so a
    #     plain directory costs nothing.
    if __gb_find_up pom.xml; then
        local pom="${REPLY}/pom.xml"
        if __gb_java_version; then
            __gb_add blue fg0 " ${__gb_icon_java} ${REPLY} "
        fi
        if __gb_maven_version "$pom"; then
            __prompt_quote "$REPLY"
            __gb_add blue fg0 " ${__gb_icon_package} ${REPLY} "
        fi
    elif __gb_find_up build.gradle || __gb_find_up build.gradle.kts; then
        if __gb_java_version; then
            __gb_add blue fg0 " ${__gb_icon_java} ${REPLY} "
        fi
    fi

    if __gb_find_up package.json && __gb_node_version; then
        __gb_add blue fg0 " ${__gb_icon_node} ${REPLY} "
    fi

    if [[ -n ${VIRTUAL_ENV-} ]] && __gb_python_version; then
        __gb_add blue fg0 " ${__gb_icon_python} ${REPLY} "
    fi

    # 5 - docker context, grey.
    if __gb_docker_context; then
        __prompt_quote "$REPLY"
        __gb_add bg3 blue_bright " ${__gb_icon_docker} ${REPLY} "
    fi

    # The first powerline line ends with the working directory. The remaining
    # segments start a fresh powerline band on line two.
    __gb_close
    __gb_ps1+='\n'

    # 6 - clock, duration and exit code dark grey.
    if (( ! PROMPT_GRUVBOX_TIME_ON_INPUT_LINE )); then
        tail+=" ${__gb_icon_clock} \\A"
    fi
    if [[ -n $duration ]] && (( rc != 0 || elapsed >= PROMPT_GRUVBOX_MIN_DURATION_US )); then
        tail+=" ${__gb_icon_duration} ${duration}"
    fi
    if (( PROMPT_GRUVBOX_SHOW_COMMAND )) &&
        __prompt_last_command "$PROMPT_GRUVBOX_COMMAND_MAX_LEN"; then
        tail+=" ${__gb_fg[blue_bright]}${REPLY}${__gb_fg[fg0]}"
    fi
    if (( rc != 0 )); then
        tail+=" ${__gb_fg[red]}${__gb_icon_error} ${rc}${__gb_fg[fg0]}"
    fi
    [[ -z $tail ]] || __gb_add bg1 fg0 "${tail} "

    __gb_close

    # 7 - the input line (line three).
    if (( EUID == 0 )); then
        symbol='#'
        symbol_color=${__gb_fg[red]}
    elif (( rc != 0 )); then
        symbol=$'\u276f'
        symbol_color=${__gb_fg[red]}
    else
        symbol=$'\u276f'
        symbol_color=${__gb_fg[green]}
    fi

    __gb_ps1+='\n'
    if (( PROMPT_GRUVBOX_TIME_ON_INPUT_LINE )); then
        __gb_ps1+="${__gb_fg[bg3]}\\A${__gb_reset} "
    fi
    __gb_ps1+="${symbol_color}${symbol}${__gb_reset} "

    PS1=$__gb_ps1
}

# --- wiring -----------------------------------------------------------------

# Same ordering contract as prompt-local.sh: the timer stops first so the exit
# code and the duration are already known, existing prompt hooks run next, the
# prompt is built afterwards, and the DEBUG trap is armed last. In particular,
# history.sh has already installed __history_append here. prompt-core.sh owns
# the string/array representation and keeps that existing hook intact.
__prompt_command_prepend __cmd_timer_stop
__prompt_command_append __gb_build __cmd_timer_arm

__gb_build
