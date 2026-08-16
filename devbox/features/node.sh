#!/usr/bin/env bash
# Node.js installation via NodeSource, pinned to NODE_VERSION.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on curl_with_retry()/silent()/msg_*() from install.sh's own bootstrap
# chain, and NODE_VERSION from install.sh's version manifest.

set -Eeuo pipefail

install_nodejs() {
  msg_info "Installing Node.js ${NODE_VERSION}"

  if [[ "$(node --version 2>/dev/null || true)" != "v${NODE_VERSION}."* ]]; then
    nodesource_setup="$(mktemp)"

    curl_with_retry \
      "https://deb.nodesource.com/setup_${NODE_VERSION}.x" \
      "$nodesource_setup"

    silent bash "$nodesource_setup"

    rm -f "$nodesource_setup"

    silent apt-get install \
      -y \
      --no-install-recommends \
      nodejs
  fi

  if [[ "$(node --version)" != "v${NODE_VERSION}."* ]]; then
    msg_error "Unexpected Node.js version: $(node --version 2>/dev/null || echo none)"
    exit 1
  fi

  msg_ok "Installed Node.js $(node --version)"
}
