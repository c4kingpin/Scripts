#!/usr/bin/env bash
# Shared operational helpers used by install.sh across installation phases.
#
# This file is downloaded and sourced by install.sh *after* its bootstrap
# preflight (root/OS/network checks, module loading) has already run.
# Nothing in here may be needed before that point in install.sh.

set -Eeuo pipefail

verify_checksum() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual

  actual="$(sha256sum "$file" | awk '{print $1}')"

  if [[ -z "$expected" ]]; then
    rm -f "$file"
    msg_error "No known checksum for ${label}; refusing to install it."
    exit 1
  fi

  if [[ "$actual" != "$expected" ]]; then
    rm -f "$file"
    msg_error "Checksum mismatch for ${label} (expected ${expected}, got ${actual})."
    exit 1
  fi

  msg_ok "Verified checksum for ${label}"
}

run_as_dev() (
  cd "$DEV_HOME"

  exec runuser \
    -u "$DEV_USER" \
    -- \
    env \
      HOME="$DEV_HOME" \
      USER="$DEV_USER" \
      LOGNAME="$DEV_USER" \
      SHELL="/bin/bash" \
      LANG="C.UTF-8" \
      LC_ALL="C.UTF-8" \
      PATH="${DEV_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
      "$@"
)
