# Diesen Ladeblock in die LOKALE ~/.bashrc aufnehmen.
# install.sh erledigt das automatisch. Nicht zusaetzlich erforderlich.
# Der bestehende lokale Prompt und bash-git-prompt bleiben unveraendert.
[[ ! -r "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh" ]] || source "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh"

# Optional: normales ssh fuer bestimmte Aliase auf sshp umleiten.
# Nur bei Bedarf die folgenden Zeilen entkommentieren und Aliase anpassen.
# Ein bestehender eigener ssh()-Wrapper wird dadurch ersetzt.
# ssh() {
#     if (( $# == 1 )) && [[ $1 == devbox || $1 == testbox ]]; then
#         sshp "$1"
#     else
#         command ssh "$@"
#     fi
# }

# Optional: anstelle der mitgelieferten Datei die eigene Konfiguration nutzen.
# Diese muss OHNE lokale Dateien, Windows-Pfade und Git-Plugin lauffaehig sein.
# PROMPT_SYNC_FILE="$HOME/.config/bash/prompt.sh"
