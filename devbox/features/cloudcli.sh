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

# Where this box's chosen bind address lives. devbox update re-runs the
# installer without DEVBOX_CLOUDCLI_HOST/PORT, so without persisting them an
# update would silently rewrite the unit back to loopback and cut off a box
# that had deliberately been opened to the LAN. Root-owned, dev-readable,
# the same treatment the remote-provider selection gets.
CLOUDCLI_CONFIG_FILE="${ROOT_STATE_DIR}/cloudcli.env"

# Resolution order: explicit environment variable, then this box's persisted
# choice, then the default.
devbox_cloudcli_persisted() {
  local key="$1"

  [[ -r "$CLOUDCLI_CONFIG_FILE" ]] || return 1

  awk \
    -F= \
    -v key="$key" \
    '$1 == key { print substr($0, index($0, "=") + 1) }' \
    "$CLOUDCLI_CONFIG_FILE" \
    | grep .
}

# Loopback by default, like Multica's and OpenChamber's web UIs: CloudCLI is
# shell access as the dev user over plain HTTP, so publishing it onto the
# container network is an explicit decision, not something the installer
# does on its own. 3001 is CloudCLI's own default port and deliberately
# clear of Multica (3000/8080) and OpenChamber (3000).
CLOUDCLI_BIND_HOST="${DEVBOX_CLOUDCLI_HOST:-$(devbox_cloudcli_persisted CLOUDCLI_HOST || printf '127.0.0.1')}"
CLOUDCLI_BIND_PORT="${DEVBOX_CLOUDCLI_PORT:-$(devbox_cloudcli_persisted CLOUDCLI_PORT || printf '3001')}"

[[ "$CLOUDCLI_BIND_PORT" =~ ^[0-9]{1,5}$ ]] || {
  msg_error "Invalid CloudCLI port: ${CLOUDCLI_BIND_PORT}"
  exit 1
}

[[ "$CLOUDCLI_BIND_HOST" =~ ^[0-9a-zA-Z.:_-]+$ ]] || {
  msg_error "Invalid CloudCLI bind address: ${CLOUDCLI_BIND_HOST}"
  exit 1
}

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

  # Recorded before the unit is written, so the next devbox update finds it.
  cat <<EOF >"$CLOUDCLI_CONFIG_FILE"
# Managed by the DevBox installer; read back on every re-run.
CLOUDCLI_HOST=${CLOUDCLI_BIND_HOST}
CLOUDCLI_PORT=${CLOUDCLI_BIND_PORT}
EOF

  chmod 0644 "$CLOUDCLI_CONFIG_FILE"

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

# Task Master is the task-planning integration CloudCLI offers (PRD parsing,
# task breakdown); CloudCLI drives it but does not ship it. Installed here
# so the integration is usable without the operator having to find the
# package name. It is a plain npm install, unlike the browser runtime
# below, which needs root for its apt dependencies.
#
# The package is task-master-ai; the binaries it provides are task-master,
# task-master-mcp and task-master-ai.
install_cloudcli_taskmaster() {
  msg_info "Installing Task Master ${TASKMASTER_VERSION}"

  silent npm install \
    --global \
    "task-master-ai@${TASKMASTER_VERSION}"

  if ! npm list \
    --global \
    --depth=0 \
    task-master-ai \
    >/dev/null 2>&1; then

    msg_error "Task Master npm package was not installed correctly."
    exit 1
  fi

  msg_ok "Installed Task Master"
}

# CloudCLI's "Browser Use" feature drives a Playwright-managed Chromium. Its
# own in-app installer cannot work on a DevBox: it runs
# `playwright install-deps chromium`, which shells out to apt and therefore
# needs root, while the CloudCLI service runs as dev - and dev deliberately
# has no generic sudo here. It also installs Playwright into the service's
# working directory, which is not on the resolution path of
# `require('playwright')` from CloudCLI's own global install.
#
# Both halves are done here instead, each as the user that can actually do
# it: the npm package and the apt dependencies as root, the ~170 MB browser
# itself as dev, so it lands in the cache the service reads
# (~/.cache/ms-playwright).
#
# Set DEVBOX_CLOUDCLI_BROWSER=0 to skip it; the rest of CloudCLI works
# without a browser runtime, only "Browser Use" stays unavailable.
install_cloudcli_browser_runtime() {
  if [[ "${DEVBOX_CLOUDCLI_BROWSER:-1}" == "0" ]]; then
    msg_ok "Skipping the CloudCLI browser runtime (DEVBOX_CLOUDCLI_BROWSER=0)"
    return 0
  fi

  msg_info "Installing the CloudCLI browser runtime (Playwright ${PLAYWRIGHT_VERSION} + Chromium)"

  silent npm install \
    --global \
    "playwright@${PLAYWRIGHT_VERSION}"

  # apt dependencies for Chromium; root-only, which is exactly the step
  # CloudCLI's own in-app installer cannot perform.
  silent playwright install-deps chromium

  # The browser binary belongs to the user the service runs as, or
  # executablePath() probes the wrong cache.
  if ! run_as_dev playwright install chromium >>"$LOG_FILE" 2>&1; then
    msg_error "Chromium could not be installed for ${DEV_USER}; CloudCLI's Browser Use will stay unavailable."
    return 0
  fi

  msg_ok "Installed the CloudCLI browser runtime"
}

# Remote-provider hook (DEVBOX_REMOTE=cloudcli), called generically by
# install.sh - see devbox/README.md, "Neuen Remote-Provider hinzufügen".
# CloudCLI has no Happy-style push-notification integration, so
# install_agent_limit_notify is deliberately not called here.
remote_install_cloudcli() {
  install_cloudcli
  install_cloudcli_taskmaster
  install_cloudcli_browser_runtime
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

  run_as_dev npm list \
    --global \
    --depth=0 \
    task-master-ai

  # Remote access must survive a reboot without an interactive dev login.
  [[ -f "$CLOUDCLI_SERVICE_UNIT" ]]
  systemctl is-enabled \
    --quiet \
    "$CLOUDCLI_SERVICE"
}

# Remote-provider hook: final "how to use it" banner lines.
remote_banner_cloudcli() {
  echo -e "${YW}CloudCLI serves its web UI on ${CLOUDCLI_BIND_HOST}:${CLOUDCLI_BIND_PORT}.${CL}"

  if [[ "$CLOUDCLI_BIND_HOST" == "127.0.0.1" || "$CLOUDCLI_BIND_HOST" == "localhost" ]]; then
    echo -e "${YW}Open it through an SSH tunnel and create the single account on first visit:${CL}"
    echo
    echo "  ssh -L ${CLOUDCLI_BIND_PORT}:127.0.0.1:${CLOUDCLI_BIND_PORT} dev@<devbox-host>"
    echo
    echo -e "${YW}To reach it directly instead, reinstall with DEVBOX_CLOUDCLI_HOST=0.0.0.0${CL}"
    echo -e "${YW}(plain HTTP - put a TLS reverse proxy in front of it on an untrusted network).${CL}"
  else
    echo -e "${YW}It is reachable from the network; create the single account on first visit.${CL}"
    echo -e "${YW}Traffic is plain HTTP - put a TLS reverse proxy in front of it if the${CL}"
    echo -e "${YW}network is not trusted.${CL}"
  fi

  echo
  echo -e "${YW}It drives the Codex and Claude CLIs installed here, so sign those in:${CL}"
  echo
  echo "  devbox auth login"
}
