#!/usr/bin/env bash
# Multica agent workspace and local runtime (DEVBOX_REMOTE=multica).
#
# Multica drives the Codex and Claude CLIs installed by DevBox.  The pinned
# release archive is verified against install.sh's checksum manifest before
# its binary is installed system-wide; credentials and daemon state remain in
# the dev user's ~/.multica directory.

set -Eeuo pipefail

MULTICA_SERVICE="devbox-multica-daemon.service"
MULTICA_SERVICE_UNIT="/etc/systemd/system/${MULTICA_SERVICE}"
MULTICA_HELPER_DIR="/usr/local/lib/devbox"
MULTICA_DAEMON_START_SCRIPT="${MULTICA_HELPER_DIR}/multica-daemon-start.sh"
MULTICA_DAEMON_STOP_SCRIPT="${MULTICA_HELPER_DIR}/multica-daemon-stop.sh"

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

install_multica_daemon_service() {
  msg_info "Configuring Multica daemon service"

  install -d -m 0755 "$MULTICA_HELPER_DIR"

  cat <<'EOF' >"$MULTICA_DAEMON_START_SCRIPT"
#!/usr/bin/env bash
set -Eeuo pipefail

# An unconfigured DevBox is valid: wait for `devbox auth login` rather than
# making boot fail until the owner has supplied a Multica token.
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
  install_multica_daemon_service
}

remote_bashrc_multica() {
  : # The system service starts the daemon; no interactive-shell fallback is needed.
}

remote_validate_multica() {
  run_as_dev multica version
  [[ -f "$MULTICA_SERVICE_UNIT" ]]
  systemctl is-enabled --quiet "$MULTICA_SERVICE"
}

remote_banner_multica() {
  echo -e "${YW}After onboarding, use Multica to assign work to the installed Codex/Claude CLIs:${CL}"
  echo
  echo "  multica"
  echo "  devbox auth login"
}
