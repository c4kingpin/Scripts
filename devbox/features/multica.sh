#!/usr/bin/env bash
# Multica agent workspace and local runtime (DEVBOX_REMOTE=multica).
#
# Multica drives the Codex and Claude CLIs installed by DevBox. The pinned
# release archive is verified against install.sh's checksum manifest before
# its binary is installed system-wide. Its self-hosted server runs as a
# root-managed Docker Compose stack. It is bound to loopback by default; an
# explicitly configured external reverse proxy is allowed through a dedicated
# Docker firewall chain.

set -Eeuo pipefail

MULTICA_SERVICE="devbox-multica-daemon.service"
MULTICA_SERVICE_UNIT="/etc/systemd/system/${MULTICA_SERVICE}"
MULTICA_HELPER_DIR="/usr/local/lib/devbox"
MULTICA_DAEMON_START_SCRIPT="${MULTICA_HELPER_DIR}/multica-daemon-start.sh"
MULTICA_DAEMON_STOP_SCRIPT="${MULTICA_HELPER_DIR}/multica-daemon-stop.sh"
MULTICA_SELF_HOST_DIR="/opt/devbox/multica-self-host"
MULTICA_COMPOSE_FILE="${MULTICA_SELF_HOST_DIR}/docker-compose.yml"
MULTICA_ENV_FILE="${MULTICA_SELF_HOST_DIR}/.env"
MULTICA_COMPOSE_URL="https://raw.githubusercontent.com/multica-ai/multica/v${MULTICA_VERSION}/docker-compose.selfhost.yml"
MULTICA_PUBLIC_CONFIG_FILE="${ROOT_STATE_DIR}/multica-public.env"
MULTICA_FIREWALL_SERVICE="devbox-multica-firewall.service"
MULTICA_FIREWALL_SERVICE_UNIT="/etc/systemd/system/${MULTICA_FIREWALL_SERVICE}"

install_multica() {
  local arch archive checksum url tmp_dir

  case "$(dpkg --print-architecture)" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *)
      msg_error "Unsupported architecture for Multica: $(dpkg --print-architecture)"
      exit 1
      ;;
  esac

  archive="multica-cli-${MULTICA_VERSION}-linux-${arch}.tar.gz"
  checksum="${DEVBOX_CHECKSUMS["multica:${MULTICA_VERSION}:${arch}"]:-}"
  url="https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/${archive}"
  tmp_dir="$(mktemp -d)"

  msg_info "Installing Multica CLI ${MULTICA_VERSION}"
  curl_with_retry "$url" "${tmp_dir}/${archive}"
  verify_checksum "${tmp_dir}/${archive}" "$checksum" "Multica ${MULTICA_VERSION} (${arch})"
  tar -xzf "${tmp_dir}/${archive}" -C "$tmp_dir" multica
  install -m 0755 "${tmp_dir}/multica" /usr/local/bin/multica
  rm -rf "$tmp_dir"

  if ! /usr/local/bin/multica version >/dev/null 2>&1; then
    msg_error "Multica CLI was not installed correctly."
    exit 1
  fi

  msg_ok "Installed Multica CLI"
}

configure_multica_reverse_proxy() {
  local app_url="${DEVBOX_MULTICA_APP_URL:-}"
  local server_url="${DEVBOX_MULTICA_SERVER_URL:-}"
  local proxy_cidr="${DEVBOX_MULTICA_PROXY_CIDR:-}"
  local app_host server_host cookie_domain="" public_ws_url
  local -a app_labels server_labels common_labels
  local app_index server_index

  if [[ -z "$app_url" && -z "$server_url" && -z "$proxy_cidr" ]]; then
    return 0
  fi

  [[ -n "$app_url" && -n "$server_url" && -n "$proxy_cidr" ]] || {
    msg_error "Set DEVBOX_MULTICA_APP_URL, DEVBOX_MULTICA_SERVER_URL and DEVBOX_MULTICA_PROXY_CIDR together."
    exit 1
  }
  [[ "$app_url" =~ ^https://[^[:space:]/]+(:[0-9]+)?$ && "$server_url" =~ ^https://[^[:space:]/]+(:[0-9]+)?$ ]] || {
    msg_error "Multica reverse-proxy URLs must be HTTPS origins without a path."
    exit 1
  }
  python3 - "$proxy_cidr" <<'PY' || { msg_error "DEVBOX_MULTICA_PROXY_CIDR must be a valid IPv4 CIDR."; exit 1; }
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
if network.version != 4:
    raise ValueError("only IPv4 is currently supported")
PY

  app_host="${app_url#https://}"
  app_host="${app_host%%:*}"
  server_host="${server_url#https://}"
  server_host="${server_host%%:*}"
  public_ws_url="wss://${server_url#https://}/ws"

  # Split app/API domains need a shared session cookie. Derive the narrowest
  # common parent so app.example.com and api.example.com use .example.com.
  if [[ "$app_host" != "$server_host" ]]; then
    IFS='.' read -r -a app_labels <<<"$app_host"
    IFS='.' read -r -a server_labels <<<"$server_host"
    app_index=$((${#app_labels[@]} - 1))
    server_index=$((${#server_labels[@]} - 1))

    while (( app_index >= 0 && server_index >= 0 )) &&
      [[ "${app_labels[$app_index]}" == "${server_labels[$server_index]}" ]]; do

      common_labels=("${app_labels[$app_index]}" "${common_labels[@]}")
      app_index=$((app_index - 1))
      server_index=$((server_index - 1))
    done

    if (( ${#common_labels[@]} < 2 )); then
      msg_error "Multica app and API URLs must share a parent domain for cookie authentication."
      exit 1
    fi

    cookie_domain=".$(IFS='.'; printf '%s' "${common_labels[*]}")"
  fi

  sed -i -e '/^MULTICA_BIND_ADDRESS=/d' -e '/^FRONTEND_ORIGIN=/d' -e '/^CORS_ALLOWED_ORIGINS=/d' -e '/^COOKIE_DOMAIN=/d' -e '/^MULTICA_APP_URL=/d' -e '/^MULTICA_PUBLIC_URL=/d' -e '/^MULTICA_TRUSTED_PROXIES=/d' -e '/^REMOTE_API_URL=/d' -e '/^NEXT_PUBLIC_API_URL=/d' -e '/^NEXT_PUBLIC_WS_URL=/d' "$MULTICA_ENV_FILE"
  cat <<EOF >>"$MULTICA_ENV_FILE"
MULTICA_BIND_ADDRESS=0.0.0.0
FRONTEND_ORIGIN=${app_url}
CORS_ALLOWED_ORIGINS=${app_url}
COOKIE_DOMAIN=${cookie_domain}
MULTICA_APP_URL=${app_url}
MULTICA_PUBLIC_URL=${server_url}
MULTICA_TRUSTED_PROXIES=${proxy_cidr}
REMOTE_API_URL=${server_url}
NEXT_PUBLIC_API_URL=${server_url}
NEXT_PUBLIC_WS_URL=${public_ws_url}
EOF
  cat <<EOF >"$MULTICA_PUBLIC_CONFIG_FILE"
MULTICA_APP_URL=${app_url}
MULTICA_SERVER_URL=${server_url}
EOF
  chmod 0600 "$MULTICA_ENV_FILE"
  chown root:root "$MULTICA_PUBLIC_CONFIG_FILE"
  chmod 0644 "$MULTICA_PUBLIC_CONFIG_FILE"

  cat <<EOF >"$MULTICA_FIREWALL_SERVICE_UNIT"
[Unit]
Description=Restrict Multica ports to the reverse proxy
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'iptables -N DEVBOX_MULTICA 2>/dev/null || true; iptables -F DEVBOX_MULTICA; iptables -A DEVBOX_MULTICA -s "${proxy_cidr}" -j ACCEPT; iptables -A DEVBOX_MULTICA -j DROP; iptables -C DOCKER-USER -p tcp -m multiport --dports 3000,8080 -j DEVBOX_MULTICA 2>/dev/null || iptables -I DOCKER-USER 1 -p tcp -m multiport --dports 3000,8080 -j DEVBOX_MULTICA'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$MULTICA_FIREWALL_SERVICE_UNIT"
  chmod 0644 "$MULTICA_FIREWALL_SERVICE_UNIT"
  systemctl daemon-reload
  systemctl enable "$MULTICA_FIREWALL_SERVICE"
  systemctl restart "$MULTICA_FIREWALL_SERVICE"
  msg_ok "Restricted Multica ports to reverse proxy ${proxy_cidr}"
}

install_multica_self_host() {
  msg_info "Installing Multica self-host dependencies"

  silent apt-get install \
    -y \
    docker.io \
    docker-compose-v2

  systemctl enable --now docker.service

  if ! docker info >/dev/null 2>&1; then
    msg_error "Docker cannot run in this LXC container. Enable nesting for the container, then re-run the installer."
    exit 1
  fi

  install -d -o root -g root -m 0700 "$MULTICA_SELF_HOST_DIR"
  curl_with_retry "$MULTICA_COMPOSE_URL" "$MULTICA_COMPOSE_FILE"
  # shellcheck disable=SC2016 # Compose must expand this value from .env later.
  sed -i 's/127\.0\.0\.1:/${MULTICA_BIND_ADDRESS:-127.0.0.1}:/g' "$MULTICA_COMPOSE_FILE"
  chown root:root "$MULTICA_COMPOSE_FILE"
  chmod 0644 "$MULTICA_COMPOSE_FILE"

  if [[ ! -f "$MULTICA_ENV_FILE" ]]; then
    (
      umask 077
      cat <<EOF >"$MULTICA_ENV_FILE"
POSTGRES_DB=multica
POSTGRES_USER=multica
POSTGRES_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
MULTICA_VCS_SECRET_KEY=$(openssl rand -hex 32)
MULTICA_IMAGE_TAG=v${MULTICA_VERSION}
EOF
    )
    chown root:root "$MULTICA_ENV_FILE"
    chmod 0600 "$MULTICA_ENV_FILE"
  fi

  configure_multica_reverse_proxy

  msg_info "Starting self-hosted Multica ${MULTICA_VERSION}"
  docker compose \
    --env-file "$MULTICA_ENV_FILE" \
    -f "$MULTICA_COMPOSE_FILE" \
    pull
  docker compose \
    --env-file "$MULTICA_ENV_FILE" \
    -f "$MULTICA_COMPOSE_FILE" \
    up -d

  local waited=0
  until curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; do
    if (( waited >= 90 )); then
      msg_error "Multica self-hosted backend did not become healthy; inspect: docker compose --env-file ${MULTICA_ENV_FILE} -f ${MULTICA_COMPOSE_FILE} logs"
      exit 1
    fi
    sleep 3
    waited=$((waited + 3))
  done

  msg_ok "Started self-hosted Multica (http://127.0.0.1:3000)"
}

install_multica_daemon_service() {
  msg_info "Configuring Multica daemon service"

  install -d -m 0755 "$MULTICA_HELPER_DIR"

  cat <<'EOF' >"$MULTICA_DAEMON_START_SCRIPT"
#!/usr/bin/env bash
set -Eeuo pipefail

# An unconfigured DevBox is valid: wait for `devbox auth login` rather than
# making boot fail until the owner has configured the local self-host server.
if ! curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
  echo "Multica self-hosted server is not healthy; nothing to start."
  exit 0
fi

if ! multica auth status >/dev/null 2>&1; then
  echo "Multica is not authenticated; nothing to start."
  exit 0
fi

if multica daemon status >/dev/null 2>&1; then
  echo "Multica daemon is already running."
  exit 0
fi

exec multica daemon start
EOF

  cat <<'EOF' >"$MULTICA_DAEMON_STOP_SCRIPT"
#!/usr/bin/env bash
set -Eeuo pipefail

multica daemon stop >/dev/null 2>&1 || true
EOF

  chmod 0755 "$MULTICA_DAEMON_START_SCRIPT" "$MULTICA_DAEMON_STOP_SCRIPT"

  cat <<EOF >"$MULTICA_SERVICE_UNIT"
[Unit]
Description=DevBox Multica agent daemon (user ${DEV_USER})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${DEV_USER}
Group=${DEV_USER}
Environment=HOME=${DEV_HOME}
Environment=PATH=${DEV_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${MULTICA_DAEMON_START_SCRIPT}
ExecStop=${MULTICA_DAEMON_STOP_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$MULTICA_SERVICE_UNIT"
  systemctl daemon-reload
  systemctl enable "$MULTICA_SERVICE"
  msg_ok "Configured Multica daemon service"
}

remote_install_multica() {
  install_multica
  install_multica_self_host
  install_multica_daemon_service
}

remote_bashrc_multica() {
  : # The system service starts the daemon; no interactive-shell fallback is needed.
}

remote_validate_multica() {
  run_as_dev multica version
  [[ -f "$MULTICA_SERVICE_UNIT" ]]
  systemctl is-enabled --quiet "$MULTICA_SERVICE"
  curl -fsS http://127.0.0.1:8080/healthz >/dev/null
}

remote_banner_multica() {
  echo -e "${YW}Multica is self-hosted at http://127.0.0.1:3000 and uses the installed Codex/Claude CLIs:${CL}"
  echo
  echo "  multica"
  echo "  devbox auth login"
}
