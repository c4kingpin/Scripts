#!/usr/bin/env bash
# ProjectAtlas: a repository map for coding agents
# (https://github.com/styler-ai/ProjectAtlas).
#
# An optional, opt-in feature like redis and code-server - not part of any
# profile, install with DEVBOX_FEATURES=...,projectatlas. It is a native
# Rust CLI that keeps a project-local SQLite index (folders, purposes,
# summaries, symbols, a code graph) so agents can narrow down before reading
# files broadly.
#
# Deliberately not a service and not a remote provider: `projectatlas mcp`
# is an MCP server over stdio that the agent starts itself, and the index
# lives beside each repository in .projectatlas/. There is nothing to bind
# to a port and nothing to run at boot.
#
# amd64 only. Upstream publishes Linux binaries for x86_64 and macOS
# binaries for both architectures, but no aarch64-unknown-linux-gnu build
# (checked against the v0.4.5 release). DevBox supports arm64 everywhere
# else, so this fails loudly there rather than silently skipping the
# feature the operator explicitly asked for.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on curl_with_retry()/msg_*() from install.sh's own bootstrap chain,
# verify_checksum() from lib/common.sh, and
# PROJECTATLAS_VERSION/DEVBOX_CHECKSUMS from install.sh.

set -Eeuo pipefail

PROJECTATLAS_BIN="/usr/local/bin/projectatlas"

install_projectatlas() {
  local arch archive checksum url tmp_dir

  case "$(dpkg --print-architecture)" in
    amd64)
      arch="x86_64-unknown-linux-gnu"
      ;;
    arm64)
      msg_error "ProjectAtlas publishes no Linux arm64 binary (upstream ships x86_64 Linux and macOS only)."
      msg_error "Install it from source on this architecture instead:"
      msg_error "  cargo install --git https://github.com/styler-ai/ProjectAtlas --tag v${PROJECTATLAS_VERSION} projectatlas-cli --locked"
      msg_error "Then re-run the installer without 'projectatlas' in DEVBOX_FEATURES."
      exit 1
      ;;
    *)
      msg_error "Unsupported architecture for ProjectAtlas: $(dpkg --print-architecture)"
      exit 1
      ;;
  esac

  if [[ "$("$PROJECTATLAS_BIN" --version 2>/dev/null | awk '{print $2}')" == "$PROJECTATLAS_VERSION" ]]; then
    msg_ok "ProjectAtlas ${PROJECTATLAS_VERSION} is already installed"
    return 0
  fi

  archive="projectatlas-v${PROJECTATLAS_VERSION}-${arch}.tar.gz"
  checksum="${DEVBOX_CHECKSUMS["projectatlas:${PROJECTATLAS_VERSION}:amd64"]:-}"
  url="https://github.com/styler-ai/ProjectAtlas/releases/download/v${PROJECTATLAS_VERSION}/${archive}"
  tmp_dir="$(mktemp -d)"

  msg_info "Installing ProjectAtlas ${PROJECTATLAS_VERSION}"

  curl_with_retry "$url" "${tmp_dir}/${archive}"
  verify_checksum "${tmp_dir}/${archive}" "$checksum" "ProjectAtlas ${PROJECTATLAS_VERSION} (amd64)"

  # The archive holds projectatlas/projectatlas alongside its README and
  # LICENSE; only the binary is installed.
  tar \
    -xzf "${tmp_dir}/${archive}" \
    -C "$tmp_dir" \
    projectatlas/projectatlas

  install \
    -m 0755 \
    "${tmp_dir}/projectatlas/projectatlas" \
    "$PROJECTATLAS_BIN"

  rm -rf "$tmp_dir"

  if ! "$PROJECTATLAS_BIN" --version >/dev/null 2>&1; then
    msg_error "ProjectAtlas was not installed correctly."
    exit 1
  fi

  msg_ok "Installed ProjectAtlas ${PROJECTATLAS_VERSION}"
}
