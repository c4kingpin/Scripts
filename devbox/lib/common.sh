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

# P0.1: dev owns everything under $DEV_HOME by the time these installation
# phases run, so a root-executed create/write into a dev-controlled path
# can be redirected by a symlink dev planted there in advance. Reject that
# outright instead of following it. Mirrors bin/devbox.sh's copy (which
# can't source this file - see the header comment above).
reject_symlink() {
  local path="$1"

  if [[ -L "$path" ]]; then
    msg_error "Refusing to operate on ${path}: it is a symlink"
    exit 1
  fi
}

# Writes $content to $target atomically and symlink-safely: rejects an
# existing symlink or other non-regular-file target, then writes via a
# same-directory tempfile and renames it into place (rename() replaces a
# symlink at the destination rather than following it, so even a target
# re-created between the check above and this write can't redirect the
# write outside $target's directory).
write_root_owned_file() {
  local target="$1"
  local mode="$2"
  local content="$3"
  local tmp

  reject_symlink "$target"

  if [[ -e "$target" && ! -f "$target" ]]; then
    msg_error "Refusing to write ${target}: exists but is not a regular file"
    exit 1
  fi

  tmp="$(mktemp "${target}.XXXXXX")"

  printf '%s' "$content" >"$tmp"

  chown "${DEV_USER}:${DEV_USER}" "$tmp"
  chmod "$mode" "$tmp"

  mv -f "$tmp" "$target"
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
