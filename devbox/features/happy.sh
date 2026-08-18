#!/usr/bin/env bash
# Happy: the primary session/remote layer for Codex and Claude.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on silent()/msg_*() from install.sh's own bootstrap chain, and
# HAPPY_VERSION/DEV_USER/DEV_HOME from install.sh.

set -Eeuo pipefail

HAPPY_SERVICE="devbox-happy-daemon.service"
HAPPY_SERVICE_UNIT="/etc/systemd/system/${HAPPY_SERVICE}"
HAPPY_HELPER_DIR="/usr/local/lib/devbox"
HAPPY_DAEMON_START_SCRIPT="${HAPPY_HELPER_DIR}/happy-daemon-start.sh"
HAPPY_DAEMON_STOP_SCRIPT="${HAPPY_HELPER_DIR}/happy-daemon-stop.sh"

install_happy() {
  msg_info "Installing Happy ${HAPPY_VERSION}"

  silent npm install \
    --global \
    "happy@${HAPPY_VERSION}"

  if ! npm list \
    --global \
    --depth=0 \
    happy \
    >/dev/null 2>&1; then

    msg_error "Happy npm package was not installed correctly."
    exit 1
  fi

  msg_ok "Installed Happy"
}

# Happy is the remote-access layer, so it must come up with the box: without
# this the daemon only ever started from the dev user's .bashrc, i.e. after
# somebody had already logged in locally or over SSH (issue #19). The unit is
# deliberately a Type=oneshot wrapper around `happy daemon start` (which
# spawns the daemon and returns) with a guard script that exits 0 whenever
# Happy is not paired, so an unconfigured box gets an inactive-but-clean
# service instead of a failing, restart-looping one.
install_happy_daemon_service() {
  msg_info "Configuring Happy daemon service"

  install \
    -d \
    -m 0755 \
    "$HAPPY_HELPER_DIR"

  cat <<'EOF' >"$HAPPY_DAEMON_START_SCRIPT"
#!/usr/bin/env bash
# Managed by the DevBox installer. Started by devbox-happy-daemon.service.
#
# Starts the Happy daemon for the dev user at boot, but only when Happy is
# actually installed, paired and not already running. Every "not ready" case
# exits 0 on purpose: a DevBox without Happy credentials must not produce a
# failed unit.

set -Eeuo pipefail

happy_home="${HOME}/.happy"
happy_settings="${happy_home}/settings.json"
happy_state="${happy_home}/daemon.state.json"

if ! command -v happy >/dev/null 2>&1; then
  echo "Happy is not installed; nothing to start."
  exit 0
fi

if [[ ! -s "${happy_home}/access.key" ||
      ! -s "$happy_settings" ]] ||
  ! jq \
    -e \
    '
      (.machineId? | type == "string")
      and
      (.machineId | length > 0)
    ' \
    "$happy_settings" \
    >/dev/null 2>&1; then

  echo "Happy is not paired; nothing to start."
  exit 0
fi

happy_pid="$(
  jq \
    -r \
    '.pid // empty' \
    "$happy_state" \
    2>/dev/null \
    || true
)"

if [[ "$happy_pid" =~ ^[0-9]+$ ]] &&
  kill \
    -0 \
    "$happy_pid" \
    2>/dev/null; then

  echo "Happy daemon is already running (pid ${happy_pid})."
  exit 0
fi

echo "Starting Happy daemon."

happy daemon start
EOF

  cat <<'EOF' >"$HAPPY_DAEMON_STOP_SCRIPT"
#!/usr/bin/env bash
# Managed by the DevBox installer. Stopped by devbox-happy-daemon.service.
#
# Asks Happy to shut the daemon down cleanly; never fails the unit, because
# systemd tears the remaining cgroup down afterwards anyway.

set -Eeuo pipefail

happy_state="${HOME}/.happy/daemon.state.json"

command -v happy >/dev/null 2>&1 ||
  exit 0

happy_pid="$(
  jq \
    -r \
    '.pid // empty' \
    "$happy_state" \
    2>/dev/null \
    || true
)"

[[ "$happy_pid" =~ ^[0-9]+$ ]] ||
  exit 0

kill \
  -0 \
  "$happy_pid" \
  2>/dev/null \
  || exit 0

happy daemon stop \
  || true
EOF

  chmod \
    0755 \
    "$HAPPY_DAEMON_START_SCRIPT" \
    "$HAPPY_DAEMON_STOP_SCRIPT"

  cat <<EOF >"$HAPPY_SERVICE_UNIT"
[Unit]
# Managed by the DevBox installer.
Description=DevBox Happy daemon (user ${DEV_USER})
Documentation=https://github.com/c4kingpin/Scripts
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
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
ExecStart=${HAPPY_DAEMON_START_SCRIPT}
ExecStop=${HAPPY_DAEMON_STOP_SCRIPT}
TimeoutStartSec=120
# A box that cannot reach Happy must fail quietly once, not hammer the
# service in a restart loop.
Restart=no

[Install]
WantedBy=multi-user.target
EOF

  chmod \
    0644 \
    "$HAPPY_SERVICE_UNIT"

  systemctl daemon-reload

  systemctl enable \
    --now \
    "$HAPPY_SERVICE" \
    || msg_error "Happy daemon service could not be enabled; run: systemctl status ${HAPPY_SERVICE}"

  msg_ok "Configured Happy daemon service"
}

# Remote-provider hook (DEVBOX_REMOTE=happy), called generically by
# install.sh - see devbox/README.md, "Neuen Remote-Provider hinzufügen".
# install_agent_limit_notify (features/agent-notify.sh) is called from here
# on purpose: Claude/Codex usage-limit push notifications go out over Happy,
# so they belong to Happy's own module, not to a separate condition in
# install.sh - a different provider only gets them if its own module also
# calls it.
remote_install_happy() {
  install_happy
  install_happy_daemon_service
  install_agent_limit_notify
}

# Remote-provider hook: appends Happy's dev-shell fallback snippet to
# ~/.bashrc (aliases plus a boot-service fallback starter).
remote_bashrc_happy() {
  grep \
    -Fq \
    '# DevBox Happy' \
    "${DEV_HOME}/.bashrc" \
    2>/dev/null &&
    return 0

  cat <<'EOF' >>"${DEV_HOME}/.bashrc"

# DevBox Happy
alias hclaude='happy claude'
alias hcodex='happy codex'

# Fallback for devbox-happy-daemon.service (which starts the daemon at
# boot): starts it from an interactive shell if the service is unavailable
# or did not bring it up. Only ever runs after Happy has been paired.
if [[ $- == *i* ]] &&
  [[ -z "${HAPPY_DAEMON_CHECKED:-}" ]] &&
  command -v happy >/dev/null 2>&1; then

  export HAPPY_DAEMON_CHECKED=1

  (
    if [[ -s "$HOME/.happy/access.key" &&
          -s "$HOME/.happy/settings.json" ]] &&
      jq \
        -e \
        '
          (.machineId? | type == "string")
          and
          (.machineId | length > 0)
        ' \
        "$HOME/.happy/settings.json" \
        >/dev/null 2>&1; then

      state="$HOME/.happy/daemon.state.json"

      pid="$(
        jq \
          -r \
          '.pid // empty' \
          "$state" \
          2>/dev/null \
          || true
      )"

      if [[ ! "$pid" =~ ^[0-9]+$ ]] ||
        ! kill \
          -0 \
          "$pid" \
          2>/dev/null; then

        happy daemon start \
          >/dev/null 2>&1 \
          || true
      fi
    fi
  ) >/dev/null 2>&1 &
fi
EOF
}

# Remote-provider hook: unattended (no `happy` execution) post-install
# validation.
remote_validate_happy() {
  # Do not execute Happy during unattended validation.
  run_as_dev npm list \
    --global \
    --depth=0 \
    happy

  # Remote access must survive a reboot without an interactive dev login.
  systemctl is-enabled \
    --quiet \
    devbox-happy-daemon.service
}

# Remote-provider hook: final "how to use it" banner lines.
remote_banner_happy() {
  echo -e "${YW}After onboarding, use Happy as the primary agent entry point:${CL}"
  echo
  echo "  happy"
  echo "  happy codex"
}
