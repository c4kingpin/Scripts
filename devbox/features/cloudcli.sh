#!/usr/bin/env bash
# CloudCLI, aka Claude Code UI (DEVBOX_REMOTE=cloudcli, https://cloudcli.ai).
#
# A self-hosted web/mobile UI that drives the agent CLIs DevBox already
# installs - Claude Code, Codex and Cursor CLI - so unlike OpenChamber it
# needs no separate agent runtime and works with whatever subscription those
# CLIs are already signed in to. Installed as the npm package
# @cloudcli-ai/cloudcli (binary `cloudcli`, AGPL-3.0); npm's own integrity
# check covers it, so there is no separate download/checksum step.
#
# cloudcli.ai also sells a hosted version that runs the containers itself.
# That one has nothing to install and is deliberately out of scope here -
# this module only sets up the open-source server on this DevBox.
#
# Unlike Happy, Kisuke and Multica there is no account to sign in to from a
# CLI: CloudCLI is a single-user system whose one account is created in the
# browser on first visit (POST /api/auth/register, refused once a user
# exists). It also has no service manager of its own, so DevBox owns the
# boot-time unit here - the Happy pattern, not the Kisuke one.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on silent()/msg_*() from install.sh's own bootstrap chain, and
# CLOUDCLI_VERSION/DEV_USER/DEV_HOME from install.sh.

set -Eeuo pipefail

CLOUDCLI_SERVICE="devbox-cloudcli.service"
CLOUDCLI_SERVICE_UNIT="/etc/systemd/system/${CLOUDCLI_SERVICE}"

# Loopback only, like Multica's and OpenChamber's web UIs: reachable over an
# SSH tunnel or a reverse proxy, never published onto the container network
# by the installer. 3001 is CloudCLI's own default and deliberately clear of
# Multica (3000/8080) and OpenChamber (3000).
CLOUDCLI_BIND_HOST="${DEVBOX_CLOUDCLI_HOST:-127.0.0.1}"
CLOUDCLI_BIND_PORT="${DEVBOX_CLOUDCLI_PORT:-3001}"

install_cloudcli() {
  msg_info "Installing CloudCLI ${CLOUDCLI_VERSION}"

  silent npm install \
    --global \
    "@cloudcli-ai/cloudcli@${CLOUDCLI_VERSION}"

  if ! npm list \
    --global \
    --depth=0 \
    @cloudcli-ai/cloudcli \
    >/dev/null 2>&1; then

    msg_error "CloudCLI npm package was not installed correctly."
    exit 1
  fi

  msg_ok "Installed CloudCLI"
}

# CloudCLI is the remote-access layer on this box, so it has to come up with
# the box rather than waiting for someone to log in - the same reasoning as
# Happy's unit (#19). CloudCLI has no pairing step that could leave it
# half-configured: the server always starts, and an unregistered instance
# simply shows its sign-up form. So this is a plain long-running Type=simple
# unit with Restart=on-failure, not a guard-script wrapper.
install_cloudcli_service() {
  msg_info "Configuring CloudCLI service"

  cat <<EOF >"$CLOUDCLI_SERVICE_UNIT"
[Unit]
# Managed by the DevBox installer.
Description=DevBox CloudCLI web UI (user ${DEV_USER})
Documentation=https://github.com/c4kingpin/Scripts
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DEV_USER}
Group=${DEV_USER}
WorkingDirectory=${DEV_HOME}
Environment=HOME=${DEV_HOME}
Environment=USER=${DEV_USER}
Environment=LOGNAME=${DEV_USER}
Environment=SHELL=/bin/bash
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
Environment=PATH=${DEV_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOST=${CLOUDCLI_BIND_HOST}
Environment=PORT=${CLOUDCLI_BIND_PORT}
# /usr/bin/env keeps this working whatever prefix npm installed the global
# bin into, while systemd still gets the absolute path it requires.
ExecStart=/usr/bin/env cloudcli --port ${CLOUDCLI_BIND_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  chmod \
    0644 \
    "$CLOUDCLI_SERVICE_UNIT"

  systemctl daemon-reload

  systemctl enable \
    --now \
    "$CLOUDCLI_SERVICE" \
    || msg_error "CloudCLI service could not be enabled; run: systemctl status ${CLOUDCLI_SERVICE}"

  msg_ok "Configured CloudCLI service"
}

# Remote-provider hook (DEVBOX_REMOTE=cloudcli), called generically by
# install.sh - see devbox/README.md, "Neuen Remote-Provider hinzufügen".
# CloudCLI has no Happy-style push-notification integration, so
# install_agent_limit_notify is deliberately not called here.
remote_install_cloudcli() {
  install_cloudcli
  install_cloudcli_service
}

# Remote-provider hook: CloudCLI runs as a system service that starts at
# boot, so there is no interactive-shell fallback to install - the same
# situation as Multica.
remote_bashrc_cloudcli() {
  : # The system service starts the server; no .bashrc fallback is needed.
}

# Remote-provider hook: unattended (no `cloudcli` execution) post-install
# validation.
remote_validate_cloudcli() {
  # Do not execute CloudCLI during unattended validation.
  run_as_dev npm list \
    --global \
    --depth=0 \
    @cloudcli-ai/cloudcli

  # Remote access must survive a reboot without an interactive dev login.
  [[ -f "$CLOUDCLI_SERVICE_UNIT" ]]
  systemctl is-enabled \
    --quiet \
    "$CLOUDCLI_SERVICE"
}

# Remote-provider hook: final "how to use it" banner lines.
remote_banner_cloudcli() {
  echo -e "${YW}CloudCLI serves its web UI on ${CLOUDCLI_BIND_HOST}:${CLOUDCLI_BIND_PORT}. Open it through an${CL}"
  echo -e "${YW}SSH tunnel and create the single account on first visit:${CL}"
  echo
  echo "  ssh -L ${CLOUDCLI_BIND_PORT}:127.0.0.1:${CLOUDCLI_BIND_PORT} dev@<devbox-host>"
  echo
  echo -e "${YW}It drives the Codex and Claude CLIs installed here, so sign those in:${CL}"
  echo
  echo "  devbox auth login"
}
