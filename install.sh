#!/bin/bash
set -eo pipefail

cancel_install() {
  echo
  echo "Canceled."
  exit 130
}

trap cancel_install INT

ENV=""
PRESET=""
DRY_RUN=false
NON_INTERACTIVE=false
ASSUME_YES=false
LIST_ITEMS=false
BOOTSTRAP_GUM=false
VERBOSE=false
LEGACY_STEPS_USED=false
SELECTION_PROVIDED=false

STEPS=()
REQUESTED_ITEMS=()
RESOLVED_ITEMS=()
RESOLVING_ITEMS=()
SKIPPED_ITEMS=()
PARAMS=()

ALL_STEPS=("tools" "node" "python" "keybase" "gui")
ALL_PRESETS=("minimal" "dev" "full")
ALL_GROUPS=("tools" "shell" "node" "python" "keybase" "gui")
ALL_ITEMS=(
  "tools:wsl-deps"
  "tools:homebrew"
  "tools:zsh"
  "tools:jq"
  "tools:ripgrep"
  "tools:tfenv"
  "tools:ngrok"
  "shell:antidote"
  "shell:zshenv"
  "shell:default-zsh"
  "node:nvm"
  "node:lts"
  "python:build-deps"
  "python:pyenv"
  "python:python-2.7"
  "python:python-3.12"
  "python:pipx"
  "python:poetry"
  "keybase:app"
  "gui:iterm2"
  "gui:docker"
  "gui:clipy"
  "gui:tailscale"
)

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="$HOME/.profile"
GUM_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/bin"
GUM_BIN="$GUM_CACHE_DIR/gum"
GUM_REPO="charmbracelet/gum"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  -e, --env <wsl|mac-os>       Target environment
      --preset <minimal|dev|full>
                                Select a preset
      --items <item,item>       Select granular items
  -s, --steps <step,step>       Legacy coarse steps: tools,node,python,keybase,gui
      --all                    Alias for --preset full
      --dry-run                Print the resolved plan without installing
      --list-items             Print available install items
      --bootstrap-gum          Download gum into ~/.cache/dotfiles/bin
      --non-interactive        Fail instead of prompting
  -y, --yes                    Skip interactive confirmation
      --verbose                Print shell input as it is read
  -h, --help                   Show this help
EOF
}

contains() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [ "$candidate" = "$needle" ] && return 0
  done
  return 1
}

append_unique_requested_item() {
  local item="$1"
  contains "$item" "${REQUESTED_ITEMS[@]}" || REQUESTED_ITEMS+=("$item")
}

append_unique_resolved_item() {
  local item="$1"
  contains "$item" "${RESOLVED_ITEMS[@]}" || RESOLVED_ITEMS+=("$item")
}

append_unique_skipped_item() {
  local item="$1"
  contains "$item" "${SKIPPED_ITEMS[@]}" || SKIPPED_ITEMS+=("$item")
}

clean_token() {
  local token="$1"
  token="${token// /}"
  token="${token//$'\t'/}"
  printf '%s' "$token"
}

parse_steps_arg() {
  local raw_steps="$1"
  local parsed=()
  local step
  local IFS=','
  read -ra parsed <<< "$raw_steps"
  for step in "${parsed[@]}"; do
    step="$(clean_token "$step")"
    [ -n "$step" ] && STEPS+=("$step")
  done
}

parse_items_arg() {
  local raw_items="$1"
  local parsed=()
  local item
  local IFS=','
  read -ra parsed <<< "$raw_items"
  for item in "${parsed[@]}"; do
    item="$(clean_token "$item")"
    [ -n "$item" ] && append_unique_requested_item "$item"
  done
}

is_valid_env() {
  case "$1" in
    wsl|mac-os) return 0 ;;
    *) return 1 ;;
  esac
}

is_valid_step() {
  contains "$1" "${ALL_STEPS[@]}"
}

is_valid_preset() {
  contains "$1" "${ALL_PRESETS[@]}"
}

is_valid_item() {
  contains "$1" "${ALL_ITEMS[@]}"
}

item_label() {
  case "$1" in
    tools:wsl-deps) echo "Install WSL apt dependencies" ;;
    tools:homebrew) echo "Install and initialize Homebrew" ;;
    tools:zsh) echo "Ensure zsh is available" ;;
    tools:jq) echo "Install jq" ;;
    tools:ripgrep) echo "Install ripgrep" ;;
    tools:tfenv) echo "Install tfenv" ;;
    tools:ngrok) echo "Install ngrok" ;;
    shell:antidote) echo "Initialize Antidote submodule" ;;
    shell:zshenv) echo "Link ~/.zshenv" ;;
    shell:default-zsh) echo "Set default shell to zsh" ;;
    node:nvm) echo "Install and initialize nvm" ;;
    node:lts) echo "Install Node.js LTS" ;;
    python:build-deps) echo "Install Python build dependencies" ;;
    python:pyenv) echo "Install and initialize pyenv" ;;
    python:python-2.7) echo "Install Python 2.7" ;;
    python:python-3.12) echo "Install Python 3.12" ;;
    python:pipx) echo "Install pipx" ;;
    python:poetry) echo "Install Poetry and plugins" ;;
    keybase:app) echo "Install and log in to Keybase" ;;
    gui:iterm2) echo "Install iTerm2" ;;
    gui:docker) echo "Install Docker Desktop" ;;
    gui:clipy) echo "Install Clipy" ;;
    gui:tailscale) echo "Install Tailscale" ;;
    *) echo "$1" ;;
  esac
}

group_label() {
  case "$1" in
    tools) echo "Tools" ;;
    shell) echo "Shell" ;;
    node) echo "Node" ;;
    python) echo "Python" ;;
    keybase) echo "Keybase" ;;
    gui) echo "GUI Apps" ;;
    *) echo "$1" ;;
  esac
}

item_group() {
  case "$1" in
    *:*) printf '%s' "${1%%:*}" ;;
    *) printf '%s' "$1" ;;
  esac
}

item_supported_envs() {
  case "$1" in
    tools:wsl-deps) echo "wsl" ;;
    tools:ngrok|gui:iterm2|gui:docker|gui:clipy|gui:tailscale) echo "mac-os" ;;
    *) echo "wsl mac-os" ;;
  esac
}

item_supports_env() {
  local item="$1"
  local supported_env
  for supported_env in $(item_supported_envs "$item"); do
    [ "$supported_env" = "$ENV" ] && return 0
  done
  return 1
}

item_in_group() {
  [ "$(item_group "$1")" = "$2" ]
}

item_dependencies() {
  case "$1" in
    tools:homebrew)
      [ "$ENV" = "wsl" ] && echo "tools:wsl-deps"
      ;;
    tools:zsh|tools:jq|tools:ripgrep|tools:tfenv|tools:ngrok)
      echo "tools:homebrew"
      ;;
    shell:zshenv)
      echo "shell:antidote"
      ;;
    shell:default-zsh)
      echo "tools:zsh"
      ;;
    node:nvm)
      echo "tools:homebrew"
      ;;
    node:lts)
      echo "node:nvm"
      ;;
    python:build-deps)
      [ "$ENV" = "mac-os" ] && echo "tools:homebrew"
      [ "$ENV" = "wsl" ] && echo "tools:wsl-deps"
      ;;
    python:pyenv)
      echo "tools:homebrew python:build-deps"
      ;;
    python:python-2.7|python:python-3.12)
      echo "python:pyenv"
      ;;
    python:pipx)
      echo "tools:homebrew python:python-3.12"
      ;;
    python:poetry)
      echo "python:pipx"
      ;;
    keybase:app)
      [ "$ENV" = "mac-os" ] && echo "tools:homebrew"
      [ "$ENV" = "wsl" ] && echo "tools:wsl-deps"
      ;;
    gui:iterm2|gui:docker|gui:clipy|gui:tailscale)
      echo "tools:homebrew"
      ;;
  esac
}

preset_items() {
  case "$1" in
    minimal)
      echo "tools:homebrew tools:zsh shell:antidote shell:zshenv shell:default-zsh"
      ;;
    dev)
      echo "tools:homebrew tools:zsh tools:jq tools:ripgrep tools:tfenv tools:ngrok shell:antidote shell:zshenv shell:default-zsh node:lts python:python-2.7 python:python-3.12 python:poetry"
      ;;
    full)
      echo "tools:homebrew tools:zsh tools:jq tools:ripgrep tools:tfenv tools:ngrok shell:antidote shell:zshenv shell:default-zsh node:lts python:python-2.7 python:python-3.12 python:poetry keybase:app gui:iterm2 gui:docker gui:clipy gui:tailscale"
      ;;
  esac
}

step_items() {
  case "$1" in
    tools) echo "tools:homebrew tools:zsh tools:jq tools:ripgrep tools:tfenv tools:ngrok" ;;
    node) echo "node:lts" ;;
    python) echo "python:python-2.7 python:python-3.12 python:poetry" ;;
    keybase) echo "keybase:app" ;;
    gui) echo "gui:iterm2 gui:docker gui:clipy gui:tailscale" ;;
  esac
}

append_preset_items() {
  local item
  for item in $(preset_items "$1"); do
    append_unique_requested_item "$item"
  done
}

append_step_items() {
  local step
  local item
  for step in "${STEPS[@]}"; do
    if ! is_valid_step "$step"; then
      echo "Error: Unsupported step $step" >&2
      echo "Valid steps: ${ALL_STEPS[*]}" >&2
      exit 1
    fi

    for item in $(step_items "$step"); do
      append_unique_requested_item "$item"
    done
  done

  if [ "${#STEPS[@]}" -gt 0 ]; then
    append_unique_requested_item "shell:antidote"
    append_unique_requested_item "shell:zshenv"
    append_unique_requested_item "shell:default-zsh"
  fi
}

print_items() {
  local item
  local supported
  for item in "${ALL_ITEMS[@]}"; do
    supported="$(item_supported_envs "$item")"
    printf '%-22s %s [%s]\n' "$item" "$(item_label "$item")" "$supported"
  done
}

detect_env() {
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "mac-os"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl"
  else
    echo ""
  fi
}

gum_bootstrap_command() {
  echo "./install.sh --bootstrap-gum"
}

gum_platform() {
  case "$(uname -s)" in
    Darwin) echo "Darwin" ;;
    Linux) echo "Linux" ;;
    *)
      echo "Error: unsupported gum platform: $(uname -s)" >&2
      return 1
      ;;
  esac
}

gum_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    x86_64|amd64) echo "x86_64" ;;
    *)
      echo "Error: unsupported gum architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
}

load_cached_gum() {
  if [ -x "$GUM_BIN" ]; then
    export PATH="$GUM_CACHE_DIR:$PATH"
    return 0
  fi

  return 1
}

print_gum_bootstrap_guidance() {
  echo "Interactive mode requires gum." >&2
  echo "Run this once to install a cached gum binary:" >&2
  echo "  $(gum_bootstrap_command)" >&2
}

verify_gum_archive() {
  local archive_name="$1"
  local checksums_file="$2"
  local checksum_line

  [ -f "$checksums_file" ] || return 0
  checksum_line="$(grep " $archive_name$" "$checksums_file" || true)"
  [ -n "$checksum_line" ] || return 0

  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n' "$checksum_line" | shasum -a 256 -c -
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' "$checksum_line" | sha256sum -c -
  fi
}

bootstrap_gum() {
  local platform
  local arch
  local asset_fragment
  local release_json
  local asset_url
  local checksum_url
  local tmp_dir
  local archive_name
  local gum_path

  command -v gum >/dev/null 2>&1 && return 0
  load_cached_gum && return 0
  command -v curl >/dev/null 2>&1 || { echo "Error: curl is required to bootstrap gum" >&2; return 1; }
  command -v tar >/dev/null 2>&1 || { echo "Error: tar is required to bootstrap gum" >&2; return 1; }

  platform="$(gum_platform)"
  arch="$(gum_arch)"
  asset_fragment="${platform}_${arch}"

  tmp_dir="$(mktemp -d)"

  echo "Fetching latest gum release metadata..."
  release_json="$(curl -fsSL "https://api.github.com/repos/$GUM_REPO/releases/latest")"
  asset_url="$(printf '%s\n' "$release_json" | \
    grep '"browser_download_url":' | \
    grep -i "$asset_fragment" | \
    grep '\.tar\.gz"' | \
    sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/' | \
    head -n 1 || true)"

  if [ -z "$asset_url" ]; then
    echo "Error: could not find a gum release asset for $asset_fragment" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  checksum_url="$(printf '%s\n' "$release_json" | \
    grep '"browser_download_url":' | \
    grep 'checksums.txt"' | \
    sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/' | \
    head -n 1 || true)"

  archive_name="$(basename "$asset_url")"
  echo "Downloading $archive_name..."
  curl -fsSL "$asset_url" -o "$tmp_dir/$archive_name"

  if [ -n "$checksum_url" ]; then
    curl -fsSL "$checksum_url" -o "$tmp_dir/checksums.txt"
    (cd "$tmp_dir" && verify_gum_archive "$archive_name" "$tmp_dir/checksums.txt")
  fi

  tar -xzf "$tmp_dir/$archive_name" -C "$tmp_dir"
  gum_path="$(find "$tmp_dir" -type f -name gum | head -n 1)"

  if [ -z "$gum_path" ]; then
    echo "Error: gum binary was not found in $archive_name" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  mkdir -p "$GUM_CACHE_DIR"
  cp "$gum_path" "$GUM_BIN"
  chmod +x "$GUM_BIN"
  export PATH="$GUM_CACHE_DIR:$PATH"

  echo "Installed gum to $GUM_BIN"
  rm -rf "$tmp_dir"
}

ensure_gum_for_interactive() {
  command -v gum >/dev/null 2>&1 && return 0
  load_cached_gum && return 0

  if [ "$DRY_RUN" = true ]; then
    print_gum_bootstrap_guidance
    return 1
  fi

  echo "gum is required for interactive selection. Installing a cached gum binary..."
  bootstrap_gum || {
    print_gum_bootstrap_guidance
    return 1
  }
}

gum_choose() {
  local output
  local status

  set +e
  output="$(gum choose "$@")"
  status=$?
  set -e

  [ "$status" -eq 0 ] || cancel_install
  GUM_RESULT="$output"
}

gum_confirm() {
  local status

  set +e
  gum confirm "$@"
  status=$?
  set -e

  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) cancel_install ;;
  esac
}

prompt_env() {
  local detected
  local answer
  local options=()
  detected="$(detect_env)"

  while [ -z "$ENV" ]; do
    if [ "$detected" = "wsl" ]; then
      options=("wsl" "mac-os")
    else
      options=("mac-os" "wsl")
    fi

    gum_choose --header "Environment" "${options[@]}"
    answer="$GUM_RESULT"

    if is_valid_env "$answer"; then
      ENV="$answer"
    else
      echo "Please enter mac-os or wsl."
    fi
  done
}

prompt_preset() {
  local choice

  while true; do
    gum_choose \
      --header "What do you want to install?" \
      "minimal  Minimal shell setup" \
      "dev      Dev environment" \
      "full     Full workstation" \
      "custom   Custom"
    choice="$GUM_RESULT"

    case "${choice%% *}" in
      minimal) PRESET="minimal"; SELECTION_PROVIDED=true; return ;;
      dev) PRESET="dev"; SELECTION_PROVIDED=true; return ;;
      full) PRESET="full"; SELECTION_PROVIDED=true; return ;;
      custom) prompt_custom_items; SELECTION_PROVIDED=true; return ;;
    esac
  done
}

prompt_custom_items() {
  local group

  echo
  echo "Select custom install items by group. Use space to select, enter to continue."

  for group in "${ALL_GROUPS[@]}"; do
    prompt_custom_group_items "$group"
  done

  if [ "${#REQUESTED_ITEMS[@]}" -eq 0 ]; then
    echo
    if gum_confirm "No custom items selected. Start over?"; then
      prompt_custom_items
      return
    fi

    cancel_install
  fi
}

prompt_custom_group_items() {
  local group="$1"
  local supported_items=()
  local choices=()
  local item
  local selected
  local selected_output

  for item in "${ALL_ITEMS[@]}"; do
    if item_in_group "$item" "$group" && item_supports_env "$item"; then
      supported_items+=("$item")
      choices+=("$(printf '%-22s %s' "$item" "$(item_label "$item")")")
    fi
  done

  if [ "${#supported_items[@]}" -eq 0 ]; then
    echo "$(group_label "$group")"
    echo "  No supported items for $ENV."
    return
  fi

  gum_choose \
    --no-limit \
    --header "$(group_label "$group")" \
    "${choices[@]}"
  selected_output="$GUM_RESULT"

  [ -z "$selected_output" ] && return

  while IFS= read -r selected; do
    [ -z "$selected" ] && continue
    append_unique_requested_item "${selected%% *}"
  done <<< "$selected_output"
}

confirm_plan() {
  local answer

  [ "$ASSUME_YES" = true ] && return
  [ "$DRY_RUN" = true ] && return

  echo
  read -r -p "Continue? [Y/n] " answer || true
  case "$answer" in
    ""|y|Y|yes|YES) ;;
    *) echo "Canceled."; exit 0 ;;
  esac
}

resolve_item() {
  local item="$1"
  local dep

  if ! is_valid_item "$item"; then
    echo "Error: Unsupported item $item" >&2
    exit 1
  fi

  contains "$item" "${RESOLVED_ITEMS[@]}" && return
  contains "$item" "${SKIPPED_ITEMS[@]}" && return

  if ! item_supports_env "$item"; then
    append_unique_skipped_item "$item"
    return
  fi

  if contains "$item" "${RESOLVING_ITEMS[@]}"; then
    echo "Error: dependency cycle detected at $item" >&2
    exit 1
  fi

  RESOLVING_ITEMS+=("$item")
  for dep in $(item_dependencies "$item"); do
    resolve_item "$dep"
  done

  append_unique_resolved_item "$item"
}

sort_plan_items() {
  local sorted_resolved=()
  local sorted_skipped=()
  local item

  for item in "${ALL_ITEMS[@]}"; do
    contains "$item" "${RESOLVED_ITEMS[@]}" && sorted_resolved+=("$item")
    contains "$item" "${SKIPPED_ITEMS[@]}" && sorted_skipped+=("$item")
  done

  RESOLVED_ITEMS=("${sorted_resolved[@]}")
  SKIPPED_ITEMS=("${sorted_skipped[@]}")
}

resolve_requested_items() {
  local item

  RESOLVED_ITEMS=()
  RESOLVING_ITEMS=()
  SKIPPED_ITEMS=()

  if [ -n "$PRESET" ]; then
    if ! is_valid_preset "$PRESET"; then
      echo "Error: Unsupported preset $PRESET" >&2
      echo "Valid presets: ${ALL_PRESETS[*]}" >&2
      exit 1
    fi
    append_preset_items "$PRESET"
  fi

  if [ "$LEGACY_STEPS_USED" = true ]; then
    append_step_items
  fi

  if [ "${#REQUESTED_ITEMS[@]}" -eq 0 ]; then
    echo "Error: no install items selected" >&2
    exit 1
  fi

  for item in "${REQUESTED_ITEMS[@]}"; do
    resolve_item "$item"
  done

  sort_plan_items

  if [ "${#RESOLVED_ITEMS[@]}" -eq 0 ]; then
    echo "Error: no supported install items selected for $ENV" >&2
    exit 1
  fi
}

print_plan() {
  local item

  echo
  echo "Environment: $ENV"
  echo
  echo "Will run:"
  for item in "${RESOLVED_ITEMS[@]}"; do
    printf '  - %-22s %s\n' "$item" "$(item_label "$item")"
  done

  if [ "${#SKIPPED_ITEMS[@]}" -gt 0 ]; then
    echo
    echo "Skipped for $ENV:"
    for item in "${SKIPPED_ITEMS[@]}"; do
      printf '  - %-22s %s\n' "$item" "$(item_label "$item")"
    done
  fi
}

brew_shellenv_path() {
  local brew_bin
  brew_bin="$(command -v brew || true)"

  if [ -z "$brew_bin" ]; then
    if [ "$ENV" = "wsl" ] && [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
      brew_bin="/home/linuxbrew/.linuxbrew/bin/brew"
    elif [ "$ENV" = "mac-os" ] && [ -x /opt/homebrew/bin/brew ]; then
      brew_bin="/opt/homebrew/bin/brew"
    elif [ "$ENV" = "mac-os" ] && [ -x /usr/local/bin/brew ]; then
      brew_bin="/usr/local/bin/brew"
    fi
  fi

  printf '%s' "$brew_bin"
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

install_wsl_deps() {
  sudo apt update
  sudo apt install curl git build-essential zip unzip awscli wget software-properties-common man-db vim
}

install_homebrew() {
  local brew_bin
  if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  brew_bin="$(brew_shellenv_path)"
  [ -n "$brew_bin" ] || { echo "Error: brew was not found after installation" >&2; exit 1; }

  append_once "eval \"\$($brew_bin shellenv)\"" "$PROFILE"
  eval "$("$brew_bin" shellenv)"
}

install_zsh() {
  if ! command -v zsh >/dev/null 2>&1; then
    brew install zsh
  fi
}

install_jq() {
  brew install jq
}

install_ripgrep() {
  brew install ripgrep
}

install_tfenv() {
  brew install tfenv
}

install_ngrok() {
  brew install --cask ngrok
}

install_antidote() {
  ensure_antidote
}

install_zshenv() {
  ensure_antidote
  link_once "$DOTFILES_DIR/zsh/zshenv" "$HOME/.zshenv"
}

install_default_zsh() {
  local zsh_path
  zsh_path="$(command -v zsh || true)"
  [ -n "$zsh_path" ] || { echo 'Error: zsh not found. Select tools:zsh first.' >&2; exit 1; }

  grep -qxF "$zsh_path" /etc/shells || echo "$zsh_path" | sudo tee -a /etc/shells
  sudo chsh -s "$zsh_path" "$(whoami)"
}

install_nvm() {
  brew install nvm
  mkdir -p "$HOME/.nvm"
  export NVM_DIR="$HOME/.nvm"
  append_once '[ -s "$(brew --prefix nvm)/nvm.sh" ] && \. "$(brew --prefix nvm)/nvm.sh"' "$PROFILE"
  source "$(brew --prefix nvm)/nvm.sh"
}

install_node_lts() {
  source "$(brew --prefix nvm)/nvm.sh"
  nvm install --lts
}

install_python_build_deps() {
  if [ "$ENV" = "mac-os" ]; then
    brew install openssl readline sqlite3 xz zlib tcl-tk@8
  elif [ "$ENV" = "wsl" ]; then
    sudo apt install build-essential libssl-dev zlib1g-dev \
      libbz2-dev libreadline-dev libsqlite3-dev \
      libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
  fi
}

install_pyenv() {
  brew install pyenv
  append_once 'export PYENV_ROOT="$HOME/.pyenv"' "$PROFILE"
  append_once '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' "$PROFILE"
  append_once 'eval "$(pyenv init -)"' "$PROFILE"
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init -)"
}

install_python_27() {
  pyenv install -s 2.7
}

install_python_312() {
  pyenv install -s 3.12
}

install_pipx() {
  pyenv global 3.12
  brew install pipx
  append_once 'export PIPX_DEFAULT_PYTHON="$(pyenv which python)"' "$PROFILE"
  export PIPX_DEFAULT_PYTHON="$(pyenv which python)"
  append_once 'export PATH="$PATH:$HOME/.local/bin"' "$PROFILE"
  export PATH="$PATH:$HOME/.local/bin"
}

install_poetry() {
  pipx install poetry || pipx upgrade poetry
  pipx inject poetry poetry-plugin-pyenv
  pipx inject poetry poetry-dotenv-plugin
  poetry config virtualenvs.prefer-active-python true
}

install_keybase() {
  if [ "$ENV" = "wsl" ]; then
    if ! command -v keybase >/dev/null 2>&1; then
      curl --remote-name https://prerelease.keybase.io/keybase_amd64.deb
      sudo apt install ./keybase_amd64.deb
      rm keybase_amd64.deb
    fi
    run_keybase
    keybase login
  elif [ "$ENV" = "mac-os" ]; then
    brew install --cask keybase
    if ! command -v keybase >/dev/null 2>&1; then
      [ -d /usr/local/bin ] || sudo mkdir -p /usr/local/bin
      [ -e /usr/local/bin/keybase ] || [ -L /usr/local/bin/keybase ] || \
        sudo ln -s /Applications/Keybase.app/Contents/SharedSupport/bin/keybase /usr/local/bin/keybase
      [ -e /usr/local/bin/git-remote-keybase ] || [ -L /usr/local/bin/git-remote-keybase ] || \
        sudo ln -s /Applications/Keybase.app/Contents/SharedSupport/bin/git-remote-keybase /usr/local/bin/git-remote-keybase
    fi
    keybase login
  fi
}

install_iterm2() {
  brew install --cask iterm2
}

install_docker() {
  brew install --cask docker
}

install_clipy() {
  brew install --cask clipy
}

install_tailscale() {
  brew install --cask tailscale-app
}

run_item() {
  local item="$1"

  echo
  echo "==> $(item_label "$item")"

  case "$item" in
    tools:wsl-deps) install_wsl_deps ;;
    tools:homebrew) install_homebrew ;;
    tools:zsh) install_zsh ;;
    tools:jq) install_jq ;;
    tools:ripgrep) install_ripgrep ;;
    tools:tfenv) install_tfenv ;;
    tools:ngrok) install_ngrok ;;
    shell:antidote) install_antidote ;;
    shell:zshenv) install_zshenv ;;
    shell:default-zsh) install_default_zsh ;;
    node:nvm) install_nvm ;;
    node:lts) install_node_lts ;;
    python:build-deps) install_python_build_deps ;;
    python:pyenv) install_pyenv ;;
    python:python-2.7) install_python_27 ;;
    python:python-3.12) install_python_312 ;;
    python:pipx) install_pipx ;;
    python:poetry) install_poetry ;;
    keybase:app) install_keybase ;;
    gui:iterm2) install_iterm2 ;;
    gui:docker) install_docker ;;
    gui:clipy) install_clipy ;;
    gui:tailscale) install_tailscale ;;
  esac
}

post_install() {
  if contains "python:python-3.12" "${RESOLVED_ITEMS[@]}" && contains "python:python-2.7" "${RESOLVED_ITEMS[@]}"; then
    pyenv global 3.12 2.7
  elif contains "python:python-3.12" "${RESOLVED_ITEMS[@]}"; then
    pyenv global 3.12
  elif contains "python:python-2.7" "${RESOLVED_ITEMS[@]}"; then
    pyenv global 2.7
  fi

  if [ "$ENV" = "mac-os" ] && contains "gui:iterm2" "${RESOLVED_ITEMS[@]}"; then
    echo 'Launch iterm and run `p10k configure` to install fonts and configure iterm'
  fi
}

#region Args
while (( "$#" )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -e|--env)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        ENV="$2"
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
    --preset)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        PRESET="$2"
        SELECTION_PROVIDED=true
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    --preset=*)
      if [ -n "${1#*=}" ]; then
        PRESET="${1#*=}"
        SELECTION_PROVIDED=true
      else
        echo "Error: Argument for --preset is missing" >&2
        exit 1
      fi
      shift
      ;;
    --items)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        parse_items_arg "$2"
        SELECTION_PROVIDED=true
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    --items=*)
      if [ -n "${1#*=}" ]; then
        parse_items_arg "${1#*=}"
        SELECTION_PROVIDED=true
      else
        echo "Error: Argument for --items is missing" >&2
        exit 1
      fi
      shift
      ;;
    -s|--steps)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        parse_steps_arg "$2"
        LEGACY_STEPS_USED=true
        SELECTION_PROVIDED=true
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    --steps=*)
      if [ -n "${1#*=}" ]; then
        parse_steps_arg "${1#*=}"
        LEGACY_STEPS_USED=true
        SELECTION_PROVIDED=true
      else
        echo "Error: Argument for --steps is missing" >&2
        exit 1
      fi
      shift
      ;;
    --all)
      PRESET="full"
      SELECTION_PROVIDED=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --list-items)
      LIST_ITEMS=true
      shift
      ;;
    --bootstrap-gum)
      BOOTSTRAP_GUM=true
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    -y|--yes)
      ASSUME_YES=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -*|--*=)
      echo "Error: Unsupported flag $1" >&2
      exit 1
      ;;
    *)
      PARAMS+=("$1")
      shift
      ;;
  esac
done
#endregion

[ "$VERBOSE" = true ] && set -v
set -- "${PARAMS[@]}"

if [ "$BOOTSTRAP_GUM" = true ]; then
  if [ "$DRY_RUN" = true ]; then
    echo "Would install gum to $GUM_BIN"
  else
    bootstrap_gum
  fi
  exit 0
fi

if [ "$LIST_ITEMS" = true ]; then
  if [ -n "$ENV" ] && ! is_valid_env "$ENV"; then
    echo 'Error: ENV must be one of: wsl, mac-os' >&2
    exit 1
  fi

  print_items
  exit 0
fi

if { [ -z "$ENV" ] || [ "$SELECTION_PROVIDED" = false ]; } && [ "$NON_INTERACTIVE" = false ]; then
  ensure_gum_for_interactive || exit 1
fi

if [ -z "$ENV" ]; then
  if [ "$NON_INTERACTIVE" = true ]; then
    echo 'ENV not set: (-e | --env=<wsl|mac-os>)' >&2
    exit 1
  fi

  prompt_env
fi

if ! is_valid_env "$ENV"; then
  echo 'Error: ENV must be one of: wsl, mac-os' >&2
  exit 1
fi

if [ "$SELECTION_PROVIDED" = false ]; then
  if [ "$NON_INTERACTIVE" = true ]; then
    echo 'Error: select --preset, --items, --steps, or --all when using --non-interactive' >&2
    exit 1
  fi

  prompt_preset
fi

resolve_requested_items
print_plan

if [ "$DRY_RUN" = true ]; then
  exit 0
fi

confirm_plan

for item in "${RESOLVED_ITEMS[@]}"; do
  run_item "$item"
done

post_install
