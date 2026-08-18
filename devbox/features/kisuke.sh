#!/usr/bin/env bash
# Kisuke Connect: alternative remote-access layer to Happy (DEVBOX_REMOTE=kisuke,
# see #43). Installs the `kisuke` CLI (npm package @kisuke/cli), whose
# postinstall hook downloads the actual platform binary from Kisuke's CDN -
# there is no separate versioned download/checksum step comparable to
# Erlang/OTP, npm's own integrity check covers the installer package itself.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on silent()/msg_*() from install.sh's own bootstrap chain, and
# KISUKE_VERSION/DEV_USER from install.sh.

set -Eeuo pipefail

install_kisuke() {
  msg_info "Installing Kisuke Connect ${KISUKE_VERSION}"

  silent npm install \
    --global \
    "@kisuke/cli@${KISUKE_VERSION}"

  if ! npm list \
    --global \
    --depth=0 \
    @kisuke/cli \
    >/dev/null 2>&1; then

    msg_error "Kisuke npm package was not installed correctly."
    exit 1
  fi

  msg_ok "Installed Kisuke Connect"
}

# Kisuke Connect manages its own boot-time service (`kisuke connect` /
# `kisuke install`, default --service-level user): a systemd --user unit
# named "kisuke", started via `systemctl --user`. Unlike Happy (which forks
# a background daemon directly, no systemd involved at login time), Kisuke's
# guided setup genuinely needs that unit manager reachable the first time
# `devbox auth login` runs it - `kisuke run` exits immediately when
# unauthenticated, and `kisuke login`/`kisuke connect` need an
# already-reachable daemon supervisor to get as far as printing a login URL
# at all. A fresh LXC container has no D-Bus user session (no login has ever
# happened), so `systemctl --user` has nothing to talk to.
#
# `loginctl enable-linger` is the standard fix: it makes systemd start a
# persistent `user@<uid>.service` (and its D-Bus bus) at boot, independent
# of any interactive login - exactly what Kisuke's own service management
# needs to work headlessly. This is the only Kisuke-specific boot-time setup
# DevBox performs; everything else (installing/starting/updating the actual
# "kisuke" unit) is Kisuke's own responsibility via `devbox auth login`.
#
# Observed in practice (issue report after #43 shipped): setting the linger
# flag alone doesn't guarantee systemd-logind has actually finished starting
# the user manager and its bus by the time this function returns - on some
# LXC hosts that transition lags a few seconds behind the flag being set. A
# `devbox onboard`/`devbox auth login` that runs immediately after install
# could then lose the race and hit `kisuke connect`'s own `systemctl --user`
# calls before there's a bus to talk to (`[K1002] ... Failed to connect to
# bus: No medium found`), even though the session comes up fine moments
# later on its own. Starting the unit explicitly and waiting for its bus
# socket to exist closes that window instead of just hoping.
enable_kisuke_user_linger() {
  msg_info "Enabling a persistent user session for Kisuke Connect"

  loginctl enable-linger "$DEV_USER"

  local dev_uid
  dev_uid="$(id -u "$DEV_USER")"

  systemctl start "user@${dev_uid}.service" || true

  local waited=0

  while [[ ! -S "/run/user/${dev_uid}/bus" ]] &&
    (( waited < 15 )); do

    sleep 1
    waited=$((waited + 1))
  done

  if [[ -S "/run/user/${dev_uid}/bus" ]]; then
    msg_ok "Enabled persistent user session (loginctl enable-linger ${DEV_USER})"
  else
    msg_error "Kisuke's D-Bus user session did not come up within 15s; devbox auth login may need a retry"
  fi
}

# Remote-provider hook (DEVBOX_REMOTE=kisuke), called generically by
# install.sh - see devbox/README.md, "Neuen Remote-Provider hinzufügen".
# Kisuke has no Happy-style push-notification integration; only Happy's own
# module (features/happy.sh) wires up agent limit notifications.
remote_install_kisuke() {
  install_kisuke
  enable_kisuke_user_linger
}

# Remote-provider hook: appends Kisuke's dev-shell fallback snippet to
# ~/.bashrc (nudges its systemd --user unit awake if the lingering session
# didn't bring it up already).
remote_bashrc_kisuke() {
  grep \
    -Fq \
    '# DevBox Kisuke' \
    "${DEV_HOME}/.bashrc" \
    2>/dev/null &&
    return 0

  cat <<'EOF' >>"${DEV_HOME}/.bashrc"

# DevBox Kisuke
# Fallback for Kisuke's own "kisuke" systemd --user unit: nudges it awake
# from an interactive shell if the lingering user session didn't bring it
# up on its own (e.g. linger was only just enabled this boot). Only
# meaningful once Kisuke has been authenticated (run: devbox auth login) -
# `systemctl --user start` on an unauthenticated box is a harmless no-op
# retry, not a failure.
if [[ $- == *i* ]] &&
  [[ -z "${KISUKE_DAEMON_CHECKED:-}" ]] &&
  command -v kisuke >/dev/null 2>&1; then

  export KISUKE_DAEMON_CHECKED=1

  (
    systemctl --user is-active --quiet kisuke 2>/dev/null ||
      systemctl --user start kisuke >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 &
fi
EOF
}

# Remote-provider hook: unattended (no `kisuke` execution) post-install
# validation.
remote_validate_kisuke() {
  # Do not execute Kisuke during unattended validation.
  run_as_dev npm list \
    --global \
    --depth=0 \
    @kisuke/cli

  # Kisuke's own boot-time service needs a lingering user session to work
  # headlessly (see enable_kisuke_user_linger above); the "kisuke" systemd
  # --user unit itself is only installed later, by `devbox auth login`.
  [[ "$(
    loginctl show-user \
      "$DEV_USER" \
      --property=Linger \
      --value \
      2>/dev/null
  )" == "yes" ]]
}

# Remote-provider hook: final "how to use it" banner lines.
remote_banner_kisuke() {
  echo -e "${YW}After onboarding, use Codex/Claude directly and reach this box from${CL}"
  echo -e "${YW}the Kisuke app once 'devbox auth login' has authenticated Kisuke Connect:${CL}"
  echo
  echo "  codex"
  echo "  claude"
}
