#!/usr/bin/env bash
# Base OS setup: the Ubuntu universe component and the apt packages every
# other feature and the devbox manager depend on.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on silent()/msg_*() from install.sh's own bootstrap chain.

set -Eeuo pipefail

enable_ubuntu_universe() {
  msg_info "Ensuring Ubuntu universe component is enabled"

  if apt-cache policy 2>/dev/null | grep -q universe; then
    msg_ok "universe component already enabled"
  else
    silent apt-get install \
      -y \
      --no-install-recommends \
      software-properties-common

    silent add-apt-repository \
      -y \
      universe

    silent apt-get update

    msg_ok "Enabled universe component"
  fi
}

install_os_dependencies() {
  msg_info "Installing Dependencies"

  silent apt-get install \
    -y \
    --no-install-recommends \
    bash-completion \
    build-essential \
    ca-certificates \
    curl \
    fd-find \
    git \
    git-lfs \
    gh \
    gnupg \
    inotify-tools \
    jq \
    less \
    libssl-dev \
    locales \
    nano \
    openssh-server \
    openssl \
    pipx \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    rsync \
    shellcheck \
    sudo \
    tmux \
    unattended-upgrades \
    unzip \
    vim \
    wget \
    xz-utils \
    zip

  msg_ok "Installed Dependencies"
}
