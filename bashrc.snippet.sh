# Add this loader block to the LOCAL ~/.bashrc.
# install.sh does this automatically, so it is not needed on top of that.
# The existing local prompt and bash-git-prompt stay unchanged.
[[ ! -r "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh" ]] || source "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh"

# Optional: route plain ssh to sshp for selected aliases.
# ssh-prompt.sh does not define an ssh wrapper, so nothing gets overwritten
# here. Uncomment the lines below and adjust the aliases only if you want
# single hosts to sync the prompt automatically.
# ssh() {
#     if (( $# == 1 )) && [[ $1 == devbox || $1 == testbox ]]; then
#         sshp "$1"
#     else
#         command ssh "$@"
#     fi
# }

# Optional: use your own configuration instead of the bundled file.
# It has to run WITHOUT local files, Windows paths and the git plugin.
# PROMPT_SYNC_FILE="$HOME/.config/bash/prompt.sh"
