#!/bin/bash
set -v
set -eo pipefail
trap "echo; exit" INT

ENV=""
STEPS=()

ALL_STEPS=("tools" "node" "python" "keybase" "gui")
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="$HOME/.profile"

parse_steps_arg() {
  local raw_steps="$1"
  local IFS=','
  read -ra STEPS <<< "$raw_steps"
}

PARAMS=()
# https://medium.com/@Drew_Stokes/bash-argument-parsing-54f3b81a6a8f
#region Args
while (( "$#" )); do
  case "$1" in
    -e|--env)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        ENV=$2
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    --env=*)
      if [ -n "${1#*=}" ]; then
        ENV="${1#*=}"
      else
        echo "Error: Argument for --env is missing" >&2
        exit 1
      fi
      shift
      ;;
    -s|--steps)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        parse_steps_arg "$2"
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    --steps=*)
      if [ -n "${1#*=}" ]; then
        parse_steps_arg "${1#*=}"
      else
        echo "Error: Argument for --steps is missing" >&2
        exit 1
      fi
      shift
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
      PARAMS+=("$1")
      shift
      ;;
  esac
done
#endregion

[ -z "$ENV" ] && { echo 'ENV not set: (-e | --env=<wsl|mac-os>)'; exit 1; }

set -- "${PARAMS[@]}"

is_valid_step() {
  local step="$1"
  local valid_step
  for valid_step in "${ALL_STEPS[@]}"; do
    [ "$valid_step" = "$step" ] && return 0
  done
  return 1
}

selected_step() {
  local step="$1"
  local selected
  for selected in "${STEPS[@]}"; do
    [ "$selected" = "$step" ] && return 0
  done
  return 1
}

append_once() {
  local line="$1"
  local file="$2"

  touch "$file"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

link_once() {
  local source_file="$1"
  local target_file="$2"

  if [ -L "$target_file" ] && [ "$(readlink "$target_file")" = "$source_file" ]; then
    return 0
  fi

  if [ -e "$target_file" ] || [ -L "$target_file" ]; then
    echo "Error: $target_file already exists and does not point to $source_file" >&2
    exit 1
  fi

  ln -s "$source_file" "$target_file"
}

ensure_antidote() {
  if [ ! -f "$DOTFILES_DIR/antidote/antidote.zsh" ]; then
    git -C "$DOTFILES_DIR" submodule update --init --recursive antidote
  fi
}

case "$ENV" in
  wsl|mac-os) ;;
  *) echo 'Error: ENV must be one of: wsl, mac-os' >&2; exit 1 ;;
esac

for step in "${STEPS[@]}"; do
  if ! is_valid_step "$step"; then
    echo "Error: Unsupported step $step" >&2
    echo "Valid steps: ${ALL_STEPS[*]}" >&2
    exit 1
  fi
done


#region Tools
if selected_step "tools"; then
  # Install dependencies
  if [ "$ENV" = "wsl" ]; then
    sudo apt update && \
    sudo apt install curl git build-essential zip unzip awscli wget software-properties-common man-db vim
  fi

  # Install Brew
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [ "$ENV" = "wsl" ]; then
    append_once 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' "$PROFILE"
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [ "$ENV" = "mac-os" ]; then
    append_once 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$PROFILE"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  # Install zsh if not installed
  if ! [ -x "$(command -v zsh)" ]; then
    brew install zsh
  fi

  brew install jq tfenv

  if [ "$ENV" = "mac-os" ]; then
    brew install --cask ngrok
  fi
fi
#endregion

#region Node
if selected_step "node"; then
  brew install nvm

  # Complete nvm setup
  mkdir -p "$HOME/.nvm"
  export NVM_DIR="$HOME/.nvm"
  append_once '[ -s "$(brew --prefix nvm)/nvm.sh" ] && \. "$(brew --prefix nvm)/nvm.sh"' "$PROFILE"
  source "$(brew --prefix nvm)/nvm.sh"

  nvm install --lts
fi
#endregion

#region Python
if selected_step "python"; then
  if [ "$ENV" = "mac-os" ]; then
    brew install openssl readline sqlite3 xz zlib tcl-tk@8
  fi

  if [ "$ENV" = "wsl" ]; then
    sudo apt install build-essential libssl-dev zlib1g-dev \
      libbz2-dev libreadline-dev libsqlite3-dev \
      libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
  fi

  brew install pyenv
  append_once 'export PYENV_ROOT="$HOME/.pyenv"' "$PROFILE"
  append_once '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' "$PROFILE"
  append_once 'eval "$(pyenv init -)"' "$PROFILE"
  export PYENV_ROOT="$HOME/.pyenv"
  eval "$(pyenv init -)"
  [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"

  pyenv install -s 2.7
  pyenv install -s 3.12
  pyenv global 3.12 2.7

  brew install pipx
  append_once 'export PIPX_DEFAULT_PYTHON="$(pyenv which python)"' "$PROFILE"
  append_once 'export PATH="$PATH:$HOME/.local/bin"' "$PROFILE"
  export PATH="$PATH:$HOME/.local/bin"

  pipx install poetry || pipx upgrade poetry
  pipx inject poetry poetry-plugin-pyenv
  pipx inject poetry poetry-dotenv-plugin

  poetry config virtualenvs.prefer-active-python true
fi
#endregion

#region Keybase
if selected_step "keybase"; then
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
if selected_step "gui"; then
  if [ "$ENV" = "mac-os" ]; then
    brew install --cask iterm2 docker clipy
  fi
fi
#endregion

# Set default shell to zsh
zsh_path="$(command -v zsh || true)"
[ -n "$zsh_path" ] || { echo 'Error: zsh not found. Run the tools step first.' >&2; exit 1; }

ensure_antidote
grep -qxF "$zsh_path" /etc/shells || echo "$zsh_path" | sudo tee -a /etc/shells
sudo chsh -s "$zsh_path" "$(whoami)"

link_once "$DOTFILES_DIR/zsh/zshenv" "$HOME/.zshenv"

if [ "$ENV" = "mac-os" ]; then
  echo 'Launch iterm and run `p10k configure` to install fonts and configure iterm'
fi
