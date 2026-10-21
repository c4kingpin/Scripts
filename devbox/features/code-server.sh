#!/usr/bin/env bash
# code-server: VS Code in the browser (https://github.com/coder/code-server).
#
# An optional, opt-in feature like redis - not part of any profile, install
# with DEVBOX_FEATURES=...,code-server. It is deliberately *not* a remote
# provider: it is an editor, not an agent session layer, so it runs
# alongside whichever DEVBOX_REMOTE is configured (including "none") rather
# than instead of one.
#
# The release .deb is pinned and verified against install.sh's checksum
# manifest before dpkg installs it, the same treatment Erlang/OTP, Elixir
# and Multica get.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on curl_with_retry()/silent()/msg_*() from install.sh's own bootstrap
# chain, verify_checksum()/write_root_owned_file() from lib/common.sh, and
# CODE_SERVER_VERSION/DEVBOX_CHECKSUMS/DEV_USER/DEV_HOME from install.sh.

set -Eeuo pipefail

CODE_SERVER_CONFIG_DIR="${DEV_HOME}/.config/code-server"
CODE_SERVER_CONFIG_FILE="${CODE_SERVER_CONFIG_DIR}/config.yaml"

# Where this box's chosen bind address lives. devbox update re-runs the
# installer without DEVBOX_CODE_SERVER_HOST/PORT and rewrites config.yaml,
# so without persisting them an update would silently pull a deliberately
# LAN-exposed code-server back onto loopback. Root-owned, the same
# treatment the remote-provider selection gets.
CODE_SERVER_CONFIG_STATE="${ROOT_STATE_DIR}/code-server.env"

# Resolution order: explicit environment variable, then this box's
# persisted choice, then the default.
devbox_code_server_persisted() {
  local key="$1"

  [[ -r "$CODE_SERVER_CONFIG_STATE" ]] || return 1

  awk \
    -F= \
    -v key="$key" \
    '$1 == key { print substr($0, index($0, "=") + 1) }' \
    "$CODE_SERVER_CONFIG_STATE" \
    | grep .
}

# Loopback by default: code-server ships a built-in terminal, so it is
# shell access as the dev user over plain HTTP. Publishing it onto the
# container network is an explicit decision, not something the installer
# does on its own.
#
# 8080 is code-server's own default port, but Multica's self-hosted backend
# already binds 127.0.0.1:8080, and the two have to be able to coexist on
# one box (code-server is a feature, Multica a remote provider). DevBox
# therefore defaults to 8888 and leaves the port overridable.
CODE_SERVER_BIND_HOST="${DEVBOX_CODE_SERVER_HOST:-$(devbox_code_server_persisted CODE_SERVER_HOST || printf '127.0.0.1')}"
CODE_SERVER_BIND_PORT="${DEVBOX_CODE_SERVER_PORT:-$(devbox_code_server_persisted CODE_SERVER_PORT || printf '8888')}"

[[ "$CODE_SERVER_BIND_PORT" =~ ^[0-9]{1,5}$ ]] || {
  msg_error "Invalid code-server port: ${CODE_SERVER_BIND_PORT}"
  exit 1
}

[[ "$CODE_SERVER_BIND_HOST" =~ ^[0-9a-zA-Z.:_-]+$ ]] || {
  msg_error "Invalid code-server bind address: ${CODE_SERVER_BIND_HOST}"
  exit 1
}

install_code_server_package() {
  local arch package checksum url tmp_dir

  case "$(dpkg --print-architecture)" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *)
      msg_error "Unsupported architecture for code-server: $(dpkg --print-architecture)"
      exit 1
      ;;
  esac

  if [[ "$(code-server --version 2>/dev/null | head -n1 | awk '{print $1}')" == "$CODE_SERVER_VERSION" ]]; then
    msg_ok "code-server ${CODE_SERVER_VERSION} is already installed"
    return 0
  fi

  package="code-server_${CODE_SERVER_VERSION}_${arch}.deb"
  checksum="${DEVBOX_CHECKSUMS["code-server:${CODE_SERVER_VERSION}:${arch}"]:-}"
  url="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/${package}"
  tmp_dir="$(mktemp -d)"

  msg_info "Installing code-server ${CODE_SERVER_VERSION}"

  curl_with_retry "$url" "${tmp_dir}/${package}"
  verify_checksum "${tmp_dir}/${package}" "$checksum" "code-server ${CODE_SERVER_VERSION} (${arch})"

  silent apt-get install \
    -y \
    --no-install-recommends \
    "${tmp_dir}/${package}"

  rm -rf "$tmp_dir"

  if ! command -v code-server >/dev/null 2>&1; then
    msg_error "code-server was not installed correctly."
    exit 1
  fi

  msg_ok "Installed code-server ${CODE_SERVER_VERSION}"
}

# code-server writes itself a random password on first start. DevBox
# generates it up front instead, so the value exists before the service is
# ever reachable and so a re-install never silently rotates it (the same
# contract as the PostgreSQL password and the OpenChamber UI password).
configure_code_server() {
  local password=""

  msg_info "Configuring code-server access"

  # Recorded before the config is written, so the next devbox update finds
  # it instead of falling back to the loopback default.
  cat <<EOF >"$CODE_SERVER_CONFIG_STATE"
# Managed by the DevBox installer; read back on every re-run.
CODE_SERVER_HOST=${CODE_SERVER_BIND_HOST}
CODE_SERVER_PORT=${CODE_SERVER_BIND_PORT}
EOF

  chmod 0644 "$CODE_SERVER_CONFIG_STATE"

  reject_symlink "$CODE_SERVER_CONFIG_DIR"

  install \
    -d \
    -m 0700 \
    -o "$DEV_USER" \
    -g "$DEV_USER" \
    "$CODE_SERVER_CONFIG_DIR"

  if [[ -n "${DEVBOX_CODE_SERVER_PASSWORD:-}" ]]; then
    password="$DEVBOX_CODE_SERVER_PASSWORD"

    # The value becomes a bare YAML scalar below and is read back with sed,
    # so reject anything that cannot survive that round trip rather than
    # writing a config file code-server would parse differently.
    if [[ ${#password} -lt 12 ||
          "$password" =~ [[:space:]] ||
          "$password" =~ [[:cntrl:]] ]]; then

      msg_error "DEVBOX_CODE_SERVER_PASSWORD must be at least 12 characters and contain no whitespace or control characters."
      exit 1
    fi

  elif [[ -r "$CODE_SERVER_CONFIG_FILE" ]] &&
    grep \
      -q \
      '^password: ' \
      "$CODE_SERVER_CONFIG_FILE"; then

    password="$(
      sed \
        -n \
        's/^password: //p' \
        "$CODE_SERVER_CONFIG_FILE"
    )"

    # Only accept a persisted value back when it still looks like one we
    # generated; anything else is discarded in favour of a fresh password.
    # Mirrors the same guard in configure_postgres_dev_access().
    if [[ ! "$password" =~ ^[0-9a-f]{48}$ ]]; then
      msg_error "Persisted code-server password has an unexpected format; generating a new one"
      password="$(openssl rand -hex 24)"
    fi
  else
    password="$(openssl rand -hex 24)"
  fi

  local config_content
  config_content="$(cat <<EOF
# Managed by the DevBox installer; rewritten on every install/update.
# The bind address comes from /var/lib/devbox/code-server.env.
bind-addr: ${CODE_SERVER_BIND_HOST}:${CODE_SERVER_BIND_PORT}
auth: password
password: ${password}
cert: false
EOF
  )"

  write_root_owned_file "$CODE_SERVER_CONFIG_FILE" 0600 "${config_content}"$'\n'

  unset password

  msg_ok "Configured code-server access"
}

# The .deb ships a templated unit, code-server@<user>, which reads the
# config file written above. Enabling the dev instance is all DevBox has to
# do - no unit of its own.
enable_code_server_service() {
  msg_info "Enabling code-server"

  systemctl daemon-reload

  systemctl enable \
    --now \
    "code-server@${DEV_USER}" \
    || msg_error "code-server service could not be enabled; run: systemctl status code-server@${DEV_USER}"

  msg_ok "Enabled code-server"
}
