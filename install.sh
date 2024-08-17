#!/bin/bash
set -v
set -eo pipefail
trap "echo; exit" INT

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

[ -z "$ENV" ] && { echo 'ENV not set: (-e | --env=<wsl|mac-os>)'; exit 1; }

eval set -- "$PARAMS"

# Install dependencies
if [ "$ENV" = "wsl" ]; then
  sudo apt update && \
  sudo apt install curl git build-essential zip unzip awscli wget software-properties-common man-db vim
fi

# Install Brew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

if [ "$ENV" = "wsl" ]; then
  (echo; echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"') >> $HOME/.profile
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [ "$ENV" = "mac-os" ]; then
  (echo; echo 'eval "$(/opt/homebrew/bin/brew shellenv)"') >> ~/.profile
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install zsh if not installed
if ! [ -x "$(command -v zsh)" ]; then
  brew install zsh
fi

# Install dev tools
brew install nvm jq

# Complete nvm setup
mkdir ~/.nvm
export NVM_DIR="$HOME/.nvm"
echo '[ -s "$(brew --prefix nvm)/nvm.sh" ] && \. "$(brew --prefix nvm)/nvm.sh"' \
    >> $HOME/.profile
source $(brew --prefix nvm)/nvm.sh

nvm install --lts

if [ "$ENV" = "wsl" ]; then
  curl --remote-name https://prerelease.keybase.io/keybase_amd64.deb && \
  sudo apt install ./keybase_amd64.deb && \
  run_keybase && \
  rm keybase_amd64.deb && \
  keybase login
elif [ "$ENV" = "mac-os" ]; then
  brew install --cask keybase
  if ! [ -x "$(command -v keybase)" ]; then
    sudo ln -s /Applications/Keybase.app/Contents/SharedSupport/bin/keybase /usr/local/bin/keybase
    sudo ln -s /Applications/Keybase.app/Contents/SharedSupport/bin/git-remote-keybase /usr/local/bin/git-remote-keybase
  fi
  keybase login
fi

# Install GUI apps
if [ "$ENV" = "mac-os" ]; then
  brew install --cask iterm2 docker
fi

# Set default shell to zsh
[ "$(grep /zsh$ /etc/shells | wc -l)" -eq 0 ] && echo $(which zsh) | sudo tee -a /etc/shells
sudo chsh -s $(which zsh) $(whoami)

ln -s $HOME/.dotfiles/zsh/zshenv $HOME/.zshenv

