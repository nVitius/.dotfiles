#!/bin/bash
set -x
set -eo pipefail

ENV=""

PARAMS=""
while (( "$#" )); do
  case "$1" in
    -e|--env)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        ENV=$2
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    -*|--*=) # unsupported flags
      echo "Error: Unsupported flag $1" >&2
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done

eval set -- "$PARAMS"

# Install dependencies
if [[ "$ENV" -eq "wsl" ]]; then
sudo apt update && \
  sudo apt install curl git build-essential zip unzip awscli wget software-properties-common man-db vim

curl --remote-name https://prerelease.keybase.io/keybase_amd64.deb && \
  sudo apt install ./keybase_amd64.deb && \
  run_keybase && \
  rm keybase_amd64.deb && \
  keybase login
fi

# Install Brew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

if [[ "$ENV" -eq "wsl" ]]; then
  (echo; echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"') >> $HOME/.profile
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

brew install zsh nvm jq

# Complete nvm setup
mkdir ~/.nvm
export NVM_DIR="$HOME/.nvm"

if [[ "$ENV" -eq "wsl" ]]; then
  echo '[ -s "/home/linuxbrew/.linuxbrew/opt/nvm/nvm.sh" ] && \. "/home/linuxbrew/.linuxbrew/opt/nvm/nvm.sh"' \
    >> $HOME/.profile
  source /home/linuxbrew/.linuxbrew/opt/nvm/nvm.sh
fi

nvm install --lts

# Set default shell to zsh
echo $(which zsh) | sudo tee -a /etc/shells
sudo chsh -s $(which zsh) $(whoami)

ln -s $HOME/.dotfiles/zsh/zshenv $HOME/.zshenv

