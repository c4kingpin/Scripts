#!/usr/bin/env bash
# Happy: the primary session/remote layer for Codex and Claude.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on silent()/msg_*() from install.sh's own bootstrap chain, and
# HAPPY_VERSION from install.sh's version manifest.

set -Eeuo pipefail

install_happy() {
  msg_info "Installing Happy ${HAPPY_VERSION}"

  silent npm install \
    --global \
    "happy@${HAPPY_VERSION}"

  if ! npm list \
    --global \
    --depth=0 \
    happy \
    >/dev/null 2>&1; then

    msg_error "Happy npm package was not installed correctly."
    exit 1
  fi

  msg_ok "Installed Happy"
}
