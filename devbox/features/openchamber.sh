#!/usr/bin/env bash
# OpenChamber: web/PWA agent workspace (DEVBOX_REMOTE=openchamber,
# https://openchamber.dev).
#
# OpenChamber is a browser/PWA front end for OpenCode, so this module installs
# both npm packages: `@opencode/cli` (binary `opencode`, the agent runtime
# OpenChamber drives) and `@openchamber/web` (binary `openchamber`, the web
# server). Neither carries a separate versioned download/checksum step
# comparable to Erlang/OTP - npm's own integrity check covers both packages.
#
# `@opencode/cli` is OpenCode 2.x. The older `opencode-ai` package stopped at
# 1.19.x, which OpenChamber 2.5 rejects at startup ("requires OpenCode 2.0.20
# or newer"); the two also both claim the `opencode` bin name, so installing
# them side by side fails with EEXIST. Only `@opencode/cli` belongs here.
#
# Unlike Happy, Kisuke and Multica, OpenChamber has no account to sign in to:
# the web UI is guarded by a UI password. DevBox generates one at install time
# and stores it in a dev-owned 0600 env file, so `devbox auth login` can hand
# it to OpenChamber's own startup service without ever prompting for a secret
# on a headless box.
#
# The server itself runs as a systemd --user unit named "openchamber" that
# OpenChamber's own `openchamber startup enable` writes (see
# bin/devbox.sh, openchamber_auth_login). As with Kisuke, DevBox's only
# boot-time job here is enabling a lingering user session so that unit can
# start without an interactive login.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on silent()/msg_*() and write_root_owned_file() from install.sh's own
# bootstrap chain and lib/common.sh, plus OPENCHAMBER_VERSION/OPENCODE_VERSION/
# DEV_USER/DEV_HOME from install.sh.

set -Eeuo pipefail

OPENCHAMBER_ENV_FILE="${DEV_HOME}/.config/devbox/openchamber.env"

# Loopback only by default, like Multica's self-hosted stack: the UI is
# reached over an SSH tunnel or a reverse proxy, never published straight
# onto the container network by the installer.
OPENCHAMBER_BIND_HOST="${DEVBOX_OPENCHAMBER_HOST:-127.0.0.1}"
OPENCHAMBER_BIND_PORT="${DEVBOX_OPENCHAMBER_PORT:-3000}"

install_openchamber() {
  msg_info "Installing OpenCode ${OPENCODE_VERSION}"

  silent npm install \
    --global \
    "@opencode/cli@${OPENCODE_VERSION}"

  if ! npm list \
    --global \
    --depth=0 \
    @opencode/cli \
    >/dev/null 2>&1; then

    msg_error "OpenCode npm package was not installed correctly."
    exit 1
  fi

  msg_ok "Installed OpenCode"

  msg_info "Installing OpenChamber ${OPENCHAMBER_VERSION}"

  silent npm install \
    --global \
    "@openchamber/web@${OPENCHAMBER_VERSION}"

  if ! npm list \
    --global \
    --depth=0 \
    @openchamber/web \
    >/dev/null 2>&1; then

    msg_error "OpenChamber npm package was not installed correctly."
    exit 1
  fi

  msg_ok "Installed OpenChamber"
}

# OpenChamber's UI password is the only thing between a tunnelled/proxied
# port and a shell on this box, so a DevBox always has one - there is no
# "unprotected by default" state to forget about. Generated once and reused
# on every re-install/update, mirroring configure_postgres_dev_access().
configure_openchamber_credentials() {
  local ui_password=""

  msg_info "Configuring OpenChamber access"

  # ~/.config/devbox (0700, dev-owned, symlink-checked) and
  # ~/.config/openchamber are created by create_developer_user() in
  # lib/user.sh, which install.sh always runs before this hook.

  if [[ -n "${DEVBOX_OPENCHAMBER_UI_PASSWORD:-}" ]]; then
    ui_password="$DEVBOX_OPENCHAMBER_UI_PASSWORD"

    # The value ends up on a single `KEY=value` line of the env file below
    # and is read back from there with sed, so anything that cannot survive
    # that round trip is rejected up front rather than silently truncated.
    if [[ ${#ui_password} -lt 12 ||
          "$ui_password" =~ [[:space:]] ||
          "$ui_password" =~ [[:cntrl:]] ]]; then

      msg_error "DEVBOX_OPENCHAMBER_UI_PASSWORD must be at least 12 characters and contain no whitespace or control characters."
      exit 1
    fi

  elif [[ -r "$OPENCHAMBER_ENV_FILE" ]] &&
    grep \
      -q \
      '^OPENCHAMBER_UI_PASSWORD=' \
      "$OPENCHAMBER_ENV_FILE"; then

    ui_password="$(
      sed \
        -n \
        's/^OPENCHAMBER_UI_PASSWORD=//p' \
        "$OPENCHAMBER_ENV_FILE"
    )"

    # The env file lives under the dev-writable user-state directory and the
    # value is passed on to `openchamber startup enable` as an argument.
    # Only accept it back when it still matches the format generated below;
    # anything else - a tampered value carrying shell metacharacters - is
    # discarded in favor of a fresh password. Mirrors the same guard in
    # configure_postgres_dev_access().
    if [[ ! "$ui_password" =~ ^[0-9a-f]{48}$ ]]; then
      msg_error "Persisted OpenChamber UI password has an unexpected format; generating a new one"
      ui_password="$(openssl rand -hex 24)"
    fi
  else
    ui_password="$(openssl rand -hex 24)"
  fi

  local env_content
  env_content="$(cat <<EOF
# Managed by the DevBox installer. Read by 'devbox auth login', which hands
# these values to OpenChamber's own startup service.
OPENCHAMBER_HOST=${OPENCHAMBER_BIND_HOST}
OPENCHAMBER_PORT=${OPENCHAMBER_BIND_PORT}
OPENCHAMBER_UI_PASSWORD=${ui_password}
EOF
  )"

  write_root_owned_file "$OPENCHAMBER_ENV_FILE" 0600 "${env_content}"$'\n'

  unset ui_password

  msg_ok "Configured OpenChamber access"
}

# OpenChamber's boot-time service is a systemd --user unit (written by
# `openchamber startup enable` during `devbox auth login`), so it needs the
# same lingering user session Kisuke does - a fresh LXC container has no
# D-Bus user session until someone logs in interactively, and OpenChamber's
# own `startup enable` warns about exactly this. See the long rationale in
# features/kisuke.sh's enable_kisuke_user_linger().
enable_openchamber_user_linger() {
  msg_info "Enabling a persistent user session for OpenChamber"

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
    msg_error "OpenChamber's D-Bus user session did not come up within 15s; devbox auth login may need a retry"
  fi
}

# Remote-provider hook (DEVBOX_REMOTE=openchamber), called generically by
# install.sh - see devbox/README.md, "Neuen Remote-Provider hinzufügen".
# OpenChamber has no Happy-style push-notification integration, so
# install_agent_limit_notify is deliberately not called here.
remote_install_openchamber() {
  install_openchamber
  configure_openchamber_credentials
  enable_openchamber_user_linger
}

# Remote-provider hook: appends OpenChamber's dev-shell fallback snippet to
# ~/.bashrc (nudges its systemd --user unit awake if the lingering session
# didn't bring it up already).
remote_bashrc_openchamber() {
  grep \
    -Fq \
    '# DevBox OpenChamber' \
    "${DEV_HOME}/.bashrc" \
    2>/dev/null &&
    return 0

  cat <<'EOF' >>"${DEV_HOME}/.bashrc"

# DevBox OpenChamber
# Fallback for OpenChamber's own "openchamber" systemd --user unit: nudges
# it awake from an interactive shell if the lingering user session didn't
# bring it up on its own (e.g. linger was only just enabled this boot). The
# unit only exists once `devbox auth login` has run `openchamber startup
# enable`; before that this is a harmless no-op.
if [[ $- == *i* ]] &&
  [[ -z "${OPENCHAMBER_SERVICE_CHECKED:-}" ]] &&
  command -v openchamber >/dev/null 2>&1; then

  export OPENCHAMBER_SERVICE_CHECKED=1

  (
    systemctl --user is-active --quiet openchamber 2>/dev/null ||
      systemctl --user start openchamber >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 &
fi
EOF
}

# Remote-provider hook: unattended (no `openchamber`/`opencode` execution)
# post-install validation.
remote_validate_openchamber() {
  run_as_dev npm list \
    --global \
    --depth=0 \
    @openchamber/web

  run_as_dev npm list \
    --global \
    --depth=0 \
    @opencode/cli

  # Both packages ship a stub binary that their postinstall hook replaces
  # with the real platform build, so "npm says it is installed" is not
  # enough - a `--version` print is the cheapest proof the binaries are
  # actually usable. Neither starts a server or touches the network; no
  # other subcommand is run during unattended validation.
  run_as_dev openchamber --version >/dev/null
  run_as_dev opencode --version >/dev/null

  # The UI password must exist before the server is ever started.
  [[ -f "$OPENCHAMBER_ENV_FILE" ]]
  [[ "$(stat -c '%a' "$OPENCHAMBER_ENV_FILE")" == "600" ]]
  grep -q '^OPENCHAMBER_UI_PASSWORD=.' "$OPENCHAMBER_ENV_FILE"

  # OpenChamber's own systemd --user unit needs a lingering session to work
  # headlessly (see enable_openchamber_user_linger above); the unit itself is
  # only installed later, by `devbox auth login`.
  [[ "$(
    loginctl show-user \
      "$DEV_USER" \
      --property=Linger \
      --value \
      2>/dev/null
  )" == "yes" ]]
}

# Remote-provider hook: final "how to use it" banner lines.
remote_banner_openchamber() {
  echo -e "${YW}OpenChamber serves its web UI on ${OPENCHAMBER_BIND_HOST}:${OPENCHAMBER_BIND_PORT} once onboarding has${CL}"
  echo -e "${YW}enabled it. Open it through an SSH tunnel from another machine:${CL}"
  echo
  echo "  ssh -L ${OPENCHAMBER_BIND_PORT}:127.0.0.1:${OPENCHAMBER_BIND_PORT} dev@<devbox-host>"
  echo "  devbox auth login     # enables the server and prints the UI password"
  echo
  echo -e "${YW}Codex and Claude remain available directly:${CL}"
  echo
  echo "  codex"
  echo "  claude"
}
