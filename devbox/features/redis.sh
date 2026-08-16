#!/usr/bin/env bash
# Redis: an optional, opt-in feature (#10 P3). Not part of any profile by
# default - install with DEVBOX_FEATURES=...,redis. A local cache/queue for
# project work, not something every DevBox needs.
#
# Downloaded and sourced by install.sh after its bootstrap preflight.

set -Eeuo pipefail

install_redis_package() {
  msg_info "Installing Redis"

  silent apt-get install \
    -y \
    --no-install-recommends \
    redis-server

  msg_ok "Installed Redis"
}

enable_redis_service() {
  msg_info "Enabling Redis"

  systemctl enable \
    --now \
    redis-server.service

  msg_ok "Enabled Redis"
}
