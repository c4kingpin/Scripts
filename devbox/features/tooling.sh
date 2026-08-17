#!/usr/bin/env bash
# mise: general-purpose version manager for languages other than
# Erlang/Elixir (those are installed outside it, see features/elixir.sh).
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on curl_with_retry()/msg_*()/LOG_FILE from install.sh's own bootstrap
# chain, and run_as_dev() from lib/common.sh.

set -Eeuo pipefail

install_mise() {
  msg_info "Installing mise"

  mise_installer="$(mktemp)"

  curl_with_retry \
    "https://mise.run" \
    "$mise_installer"

  chmod \
    0755 \
    "$mise_installer"

  run_as_dev \
    env \
    MISE_INSTALL_PATH="${DEV_HOME}/.local/bin/mise" \
    sh "$mise_installer" \
    >>"$LOG_FILE" 2>&1

  rm -f "$mise_installer"

  msg_ok "Installed mise"
}
