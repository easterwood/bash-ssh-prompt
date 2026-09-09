#!/usr/bin/env bash

# Uebersicht der Befehle, die diese Bash-Konfiguration bereitstellt.
#
# Die Tabelle in bash_config_commands ist bewusst handgepflegt: Was ein Befehl
# tut, laesst sich nicht aus dem Code ableiten. Damit die Tabelle nicht
# unbemerkt veraltet, prueft "--check", ob jeder aufgefuehrte Befehl in der
# laufenden Shell wirklich definiert ist.

# Art eines Befehls in der laufenden Shell. Rueckgabe 1, wenn er fehlt.
__bash_commands_kind() {
    local name=$1 kind

    if alias "$name" >/dev/null 2>&1; then
        printf 'Alias\n'
        return 0
    fi

    kind=$(type -t "$name" 2>/dev/null || true)
    case $kind in
        function) printf 'Funktion\n' ;;
        builtin)  printf 'Builtin\n' ;;
        file)     printf 'Programm\n' ;;
        *)        return 1 ;;
    esac
}

__bash_commands_usage() {
    printf 'Aufruf: bash-commands [--details] [FILTER]\n'
    printf '        bash-commands --check\n'
    printf '\n'
    printf '  --details, -d  Optionen, Synonyme und Quelldatei mit anzeigen\n'
    printf '  --check        Pruefen, ob jeder Befehl definiert ist\n'
    printf '  --help, -h     Diese Hilfe anzeigen\n'
    printf '\n'
    printf 'FILTER ist ein Teilstring und ignoriert Gross-/Kleinschreibung.\n'
    printf 'Gesucht wird in Name, Synonymen und Beschreibung.\n'
}

bash_config_commands() {
    local sep=$'\x1f'
    local filter='' details=0 check=0
    local arg group row name synonyms source description options kind
    local current_group='' filter_lc width=0 found=0 missing=0
    local -a selected=()

    # GRUPPE | BEFEHL | SYNONYME | QUELLE | BESCHREIBUNG | OPTIONEN
    local -a rows=(
"Prompt und Anzeige${sep}ll${sep}-${sep}bashrc.d/listing.sh${sep}Verzeichnisinhalt mit ausgerichteten Spalten und farbigem Besitzer${sep}alle Optionen von ls"
"SSH-Verbindung${sep}ssh${sep}-${sep}ssh-prompt.sh${sep}OpenSSH-Wrapper; einfache Logins laufen ueber sshp${sep}[--force] [SSH-OPTIONEN ...] ZIEL"
"SSH-Verbindung${sep}sshp${sep}-${sep}ssh-prompt.sh${sep}Prompt-Dateien zum Ziel uebertragen und einloggen${sep}[--force] [SSH-OPTIONEN ...] ZIEL"
"SSH-Verbindung${sep}ssh-nr${sep}-${sep}bashrc.d/lib/ssh-by-number.sh${sep}Login ueber die Zielnummer aus known-hosts${sep}NR [SSH-OPTIONEN ...] | --list | --help"
"SSH-Uebersicht${sep}known-hosts${sep}ssh-known-hosts${sep}bashrc.d/lib/known-hosts.sh${sep}Bekannte SSH-Ziele mit Alias, Benutzer und Zielnummer${sep}[--lines] [--refresh] [FILTER] | --fingerprints"
"SSH-Uebersicht${sep}ssh-resolve-ips${sep}-${sep}bashrc.d/lib/ssh-resolve-ips.sh${sep}IPs aus SSH-Config und known_hosts per Reverse-DNS aufloesen${sep}[FILTER] | --refresh | --help"
"SSH-Uebersicht${sep}ssh-resolve-hosts${sep}-${sep}bashrc.d/lib/ssh-resolve-hosts.sh${sep}Hostnamen aus SSH-Config und known_hosts per DNS zu IPs aufloesen${sep}[FILTER] | --refresh | --help"
"SSH-Pflege${sep}known-hosts-clean${sep}ssh-known-hosts-clean${sep}bashrc.d/lib/known-hosts-clean.sh${sep}Veraltete known_hosts-Eintraege und Config-Aliase entfernen${sep}[--apply] | --help"
"Hilfe${sep}bash-commands${sep}bashrc-help${sep}bashrc.d/commands.sh${sep}Diese Uebersicht anzeigen${sep}[--details] [FILTER] | --check | --help"
    )

    while (( $# )); do
        arg=$1
        shift

        case $arg in
            --details|-d)
                details=1
                ;;
            --check)
                check=1
                ;;
            --help|-h)
                __bash_commands_usage
                return 0
                ;;
            --)
                if (( $# > 1 )); then
                    printf 'bash-commands: Es ist nur ein FILTER erlaubt.\n' >&2
                    return 2
                fi
                if (( $# == 1 )); then
                    [[ -z $filter ]] || {
                        printf 'bash-commands: Es ist nur ein FILTER erlaubt.\n' >&2
                        return 2
                    }
                    filter=$1
                    shift
                fi
                ;;
            -*)
                printf 'bash-commands: unbekannte Option: %s\n' "$arg" >&2
                __bash_commands_usage >&2
                return 2
                ;;
            *)
                if [[ -n $filter ]]; then
                    printf 'bash-commands: Es ist nur ein FILTER erlaubt.\n' >&2
                    return 2
                fi
                filter=$arg
                ;;
        esac
    done

    if (( check )); then
        if (( details )) || [[ -n $filter ]]; then
            printf 'bash-commands: --check kann nicht mit FILTER oder --details kombiniert werden.\n' >&2
            return 2
        fi

        # Synonyme werden eingerueckt und koennen laenger sein als der Befehl.
        for row in "${rows[@]}"; do
            IFS=$sep read -r group name synonyms source description options <<< "$row"
            ((${#name} > width)) && width=${#name}
            if [[ $synonyms != '-' ]] && (( ${#synonyms} + 2 > width )); then
                width=$(( ${#synonyms} + 2 ))
            fi
        done
        ((width >= 18)) || width=18

        printf '\e[2m%-*s  %-10s  %s\e[0m\n' "$width" 'BEFEHL' 'ART' 'QUELLE'
        for row in "${rows[@]}"; do
            IFS=$sep read -r group name synonyms source description options <<< "$row"

            if kind=$(__bash_commands_kind "$name"); then
                printf '\e[36m%-*s\e[0m  %-10s  \e[2m%s\e[0m\n' \
                    "$width" "$name" "$kind" "$source"
            else
                printf '\e[36m%-*s\e[0m  \e[31m%-10s\e[0m  \e[2m%s\e[0m\n' \
                    "$width" "$name" 'fehlt' "$source"
                ((missing+=1))
            fi

            # Synonyme muessen ebenfalls existieren, sonst ist die Tabelle alt.
            if [[ $synonyms != '-' ]]; then
                if kind=$(__bash_commands_kind "$synonyms"); then
                    printf '\e[36m%-*s\e[0m  %-10s  \e[2m%s\e[0m\n' \
                        "$width" "  $synonyms" "$kind" 'Synonym'
                else
                    printf '\e[36m%-*s\e[0m  \e[31m%-10s\e[0m  \e[2m%s\e[0m\n' \
                        "$width" "  $synonyms" 'fehlt' 'Synonym'
                    ((missing+=1))
                fi
            fi
        done

        printf '\n'
        if (( missing )); then
            printf '%d Eintrag/Eintraege fehlen. Ist die Tabelle in bashrc.d/commands.sh aktuell?\n' \
                "$missing"
            return 1
        fi
        printf 'Alle aufgefuehrten Befehle sind definiert.\n'
        return 0
    fi

    filter_lc=${filter,,}

    for row in "${rows[@]}"; do
        IFS=$sep read -r group name synonyms source description options <<< "$row"

        if [[ -n $filter ]]; then
            local haystack="$name $synonyms $description"
            [[ ${haystack,,} == *"$filter_lc"* ]] || continue
        fi

        selected+=("$row")
        found=1
        ((${#name} > width)) && width=${#name}
    done

    ((width >= 18)) || width=18

    if (( ! found )); then
        printf 'Keine Befehle fuer "%s" gefunden.\n' "$filter"
        return 0
    fi

    for row in "${selected[@]}"; do
        IFS=$sep read -r group name synonyms source description options <<< "$row"

        if [[ $group != "$current_group" ]]; then
            [[ -z $current_group ]] || printf '\n'
            printf '\e[1m%s\e[0m\n' "$group"
            current_group=$group
        fi

        printf '  \e[36m%-*s\e[0m  %s' "$width" "$name" "$description"
        __bash_commands_kind "$name" >/dev/null ||
            printf ' \e[31m(nicht definiert)\e[0m'
        printf '\n'

        (( details )) || continue

        printf '  %-*s  \e[2mAufruf:\e[0m   %s\n' "$width" '' "$options"
        [[ $synonyms == '-' ]] ||
            printf '  %-*s  \e[2mSynonym:\e[0m  %s\n' "$width" '' "$synonyms"
        printf '  %-*s  \e[2mQuelle:\e[0m   %s\n' "$width" '' "$source"
    done

    if (( ! details )); then
        printf '\n\e[2m%s\e[0m\n' \
            'Mehr Details: bash-commands --details   Doku: docs/ im Git-Projekt'
    fi

    return 0
}
