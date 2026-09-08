#!/usr/bin/env bash

# Gemeinsamer SSH-Config-Scanner fuer known-hosts und dessen Completion.
# Ergebnisarrays werden vor jedem Scan zurueckgesetzt.
declare -a __kh_scan_aliases=()
declare -a __kh_scan_files=()
declare -a __kh_scan_include_patterns=()
declare -A __kh_scan_alias_seen=()
declare -A __kh_scan_file_seen=()
declare -A __kh_scan_include_seen=()

__kh_scan_reset() {
    __kh_scan_aliases=()
    __kh_scan_files=()
    __kh_scan_include_patterns=()
    __kh_scan_alias_seen=()
    __kh_scan_file_seen=()
    __kh_scan_include_seen=()
}

# Sammelt konkrete Host-Aliase und folgt Include-Anweisungen rekursiv.
# Unterstuetzt relative Pfade, absolute Pfade, ~/ und Globs.
# Tokens mit %, $ oder Leerzeichen werden bewusst nicht ausgewertet.
__kh_scan_file() {
    local file=$1 base=$2 track_includes=${3:-0}
    local line keyword token match
    local -a words

    [[ -r $file && -z ${__kh_scan_file_seen["$file"]+x} ]] || return 0

    __kh_scan_file_seen["$file"]=1
    __kh_scan_files+=("$file")

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line%%#*}
        line=${line/=/ }
        read -r -a words <<< "$line"
        ((${#words[@]})) || continue

        keyword=${words[0],,}
        for token in "${words[@]:1}"; do
            token=${token#\"}
            token=${token%\"}

            case $keyword in
                host)
                    [[ -n $token && $token != -* &&
                       $token != *['*?!']* &&
                       $token != *[[:space:][:cntrl:]]* ]] || continue

                    if [[ -z ${__kh_scan_alias_seen["$token"]+x} ]]; then
                        __kh_scan_alias_seen["$token"]=1
                        __kh_scan_aliases+=("$token")
                    fi
                    ;;

                include)
                    [[ $token != *['%$']* ]] || continue

                    case $token in
                        '~/'*) token="$HOME/${token:2}" ;;
                        /*) ;;
                        *) token="$base/$token" ;;
                    esac

                    if (( track_includes )) &&
                       [[ -z ${__kh_scan_include_seen["$token"]+x} ]]; then
                        __kh_scan_include_seen["$token"]=1
                        __kh_scan_include_patterns+=("$token")
                    fi

                    while IFS= read -r match; do
                        [[ -z $match ]] || __kh_scan_file "$match" "$base" "$track_includes"
                    done <<< "$(compgen -G "$token" || true)"
                    ;;
            esac
        done
    done < "$file"
}

# Scannt die angegebene Benutzerkonfiguration sowie die systemweite SSH-Config.
__kh_scan_configs() {
    local config=$1 track_includes=${2:-0}

    __kh_scan_reset
    __kh_scan_file "$config" "$HOME/.ssh" "$track_includes"
    __kh_scan_file /etc/ssh/ssh_config /etc/ssh "$track_includes"
}
