#!/usr/bin/env bash
# Codex CLI and Claude Code CLI, pinned to their managed versions.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on silent()/msg_*() from install.sh's own bootstrap chain, and
# CODEX_VERSION/CLAUDE_VERSION from install.sh's version manifest.

set -Eeuo pipefail

install_codex_cli() {
  msg_info "Installing Codex CLI ${CODEX_VERSION}"

  silent npm install \
    --global \
    "@openai/codex@${CODEX_VERSION}"

  msg_ok "Installed Codex CLI ${CODEX_VERSION}"
}

install_claude_cli() {
  msg_info "Installing Claude Code ${CLAUDE_VERSION}"

  silent npm install \
    --global \
    "@anthropic-ai/claude-code@${CLAUDE_VERSION}"

  msg_ok "Installed Claude Code ${CLAUDE_VERSION}"
}
