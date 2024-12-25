#!/bin/bash
set -v
set -eo pipefail
trap "echo; exit" INT

ENV=""
STEPS=""

ALL_STEPS=("tools", "node", "python", "keybase", "gui")

PARAMS=""
# https://medium.com/@Drew_Stokes/bash-argument-parsing-54f3b81a6a8f
#region Args
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
    -s|--steps)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        IFS=',' read -ra STEPS <<< "$2"
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    --all)
      STEPS=("${ALL_STEPS[@]}")
      shift
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
#endregion

[ -z "$ENV" ] && { echo 'ENV not set: (-e | --env=<wsl|mac-os>)'; exit 1; }

eval set -- "$PARAMS"


#region Tools
if [[ " ${STEPS[*]} " == *"tools"* ]]; then
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

  brew install jq tfenv
fi
#endregion

#region Node
if [[ " ${STEPS[*]} " == *"node"* ]]; then
  brew install nvm

  # Complete nvm setup
  mkdir ~/.nvm
  export NVM_DIR="$HOME/.nvm"
  echo '[ -s "$(brew --prefix nvm)/nvm.sh" ] && \. "$(brew --prefix nvm)/nvm.sh"' \
      >> $HOME/.profile
  source $(brew --prefix nvm)/nvm.sh

  nvm install --lts
fi
#endregion

#region Python
if [[ " ${STEPS[*]} " == *"python"* ]]; then
  if [ "$ENV" = "mac-os" ]; then
    brew install openssl readline sqlite3 xz zlib tcl-tk@8
  fi

  if [ "$ENV" = "wsl" ]; then
    sudo apt install build-essential libssl-dev zlib1g-dev \
      libbz2-dev libreadline-dev libsqlite3-dev \
      libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
  fi

    brew install pyenv
    echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.profile
    echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.profile
    echo 'eval "$(pyenv init -)"' >> ~/.profile
    export PYENV_ROOT="$HOME/.pyenv"
    eval "$(pyenv init -)"
    [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"

    pyenv install 3.12
    pyenv global 3.12

    brew install pipx
    echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.profile
    export PATH="$PATH:$HOME/.local/bin"

    pipx install poetry
    pip install poetry-plugin-pyenv
    pip install poetry-dotenv-plugin
fi
#endregion

#region Keybase
if [[ " ${STEPS[*]} " == *"keybase"* ]]; then
  if [ "$ENV" = "wsl" ]; then
    curl --remote-name https://prerelease.keybase.io/keybase_amd64.deb && \
    sudo apt install ./keybase_amd64.deb && \
    run_keybase && \
    rm keybase_amd64.deb && \
    keybase login
  elif [ "$ENV" = "mac-os" ]; then
    brew install --cask keybase
    if ! [ -x "$(command -v keybase)" ]; then
      [ -d /usr/local/bin ] || sudo mkdir -p /usr/local/bin
      sudo ln -s /Applications/Keybase.app/Contents/SharedSupport/bin/keybase /usr/local/bin/keybase
      sudo ln -s /Applications/Keybase.app/Contents/SharedSupport/bin/git-remote-keybase /usr/local/bin/git-remote-keybase
    fi
    keybase login
  fi
fi
#endregion

#region GUI
if [[ " ${STEPS[*]} " == *"gui"* ]]; then
  if [ "$ENV" = "mac-os" ]; then
    brew install --cask iterm2 docker clipy
  fi
fi
#endregion

# Set default shell to zsh
[ "$(grep /zsh$ /etc/shells | wc -l)" -eq 0 ] && echo $(which zsh) | sudo tee -a /etc/shells
sudo chsh -s $(which zsh) $(whoami)

ln -s $HOME/.dotfiles/zsh/zshenv $HOME/.zshenv

if [ "$ENV" = "mac-os" ]; then
  echo 'Launch iterm and run `p10k configure` to install fonts and configure iterm'
fi

