#!/usr/bin/env bash
# P1.5: real end-to-end test against an actual LXD container, as opposed to
# the static checks in test-devbox.sh (which never install anything). Needs
# a working LXD (`lxc launch` must work) and root (container management,
# apt bootstrap). Not run by `bash tests/test-devbox.sh` or the default CI
# job - see .github/workflows/lxc-integration.yml for the scheduled/manual
# CI run, or invoke this directly on a maintainer's own LXD host:
#
#   sudo DEVBOX_REPO_URL=https://raw.githubusercontent.com/c4kingpin/Scripts \
#     DEVBOX_REF=master bash devbox/tests/lxc-integration-test.sh
#
# Runs in two phases, each in its own throwaway container:
#
# Phase 1 (DEVBOX_REMOTE=happy, the default profile) exercises: fresh
# install, devbox doctor, agent CLIs, PostgreSQL access, a real
# `mix phx.new` (Elixir/Phoenix toolchain), and - the most important single
# check per issue #10 - that re-running the installer is idempotent:
# persistent state (version, features, the PostgreSQL password, an existing
# ~/.codex/config.toml) must come out unchanged. The re-install (#18 P1.2)
# uses the documented `curl | bash` one-liner rather than a file download,
# so that invocation form - where $0 is "bash", not a real script path -
# is actually exercised somewhere in CI instead of only in the README.
#
# Phase 2 (DEVBOX_REMOTE=openchamber, minimal profile) covers the one class
# of defect the static tests structurally cannot see: whether the two pinned
# npm packages actually work *together* at runtime. OpenChamber refuses to
# drive an OpenCode older than 2.0.20 and only says so when its server
# starts, so a wrong pin looks perfectly healthy to every grep-based check
# and to `npm list`. This phase therefore starts the real server through
# OpenChamber's own systemd --user unit and reads its /health endpoint,
# which reports whether the managed OpenCode came up. Elixir and PostgreSQL
# are left out here - phase 1 already covers them.

set -Eeuo pipefail

DEVBOX_REPO_URL="${DEVBOX_REPO_URL:-https://raw.githubusercontent.com/c4kingpin/Scripts}"
DEVBOX_REF="${DEVBOX_REF:-master}"
readonly DEVBOX_REPO_URL DEVBOX_REF

# Each phase gets its own container; CONTAINER names whichever one the
# helpers below currently operate on.
readonly CONTAINER_HAPPY="devbox-e2e-$$"
readonly CONTAINER_OPENCHAMBER="devbox-e2e-oc-$$"
CONTAINER="$CONTAINER_HAPPY"

readonly INSTALL_URL="${DEVBOX_REPO_URL%/}/${DEVBOX_REF}/devbox/install.sh"

# OpenChamber's web UI (phase 2). Loopback-only, as the installer configures
# it; the health probe runs inside the container.
readonly OPENCHAMBER_PORT="3000"
readonly OPENCHAMBER_HEALTH_URL="http://127.0.0.1:${OPENCHAMBER_PORT}/health"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nFAILED: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  lxc delete --force "$CONTAINER_HAPPY" >/dev/null 2>&1 || true
  lxc delete --force "$CONTAINER_OPENCHAMBER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

in_container() {
  lxc exec "$CONTAINER" -- "$@"
}

as_dev() {
  # Mirrors run_as_dev() in devbox/lib/common.sh: cd into DEV_HOME *before*
  # the runuser switch, then an explicit dev-shaped environment (not sudo -
  # dev has no generic sudo access, see P0.1). The cd matters: lxc exec's
  # default cwd is /root, which dev can't write to, and BEAM tries to write
  # erl_crash.dump relative to cwd - running from there makes `erl` fail
  # with a confusing crash instead of a clear permission error.
  lxc exec "$CONTAINER" -- bash -c '
    cd /home/dev &&
    exec runuser \
      -u dev \
      -- \
      env \
      HOME=/home/dev \
      USER=dev \
      LOGNAME=dev \
      SHELL=/bin/bash \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH="/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin" \
      "$@"
  ' _ "$@"
}

# Like as_dev, plus XDG_RUNTIME_DIR - `systemctl --user` needs it to find
# dev's D-Bus session, and neither lib/common.sh's run_as_dev nor `lxc exec`
# provides one (a real user gets it from /etc/profile.d/devbox.sh when they
# log in). Phase 2 needs it for every OpenChamber call, because OpenChamber
# manages its own systemd --user unit.
as_dev_session() {
  local dev_uid
  dev_uid="$(in_container id -u dev)"

  # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -c` shell, not here
  lxc exec "$CONTAINER" -- bash -c '
    cd /home/dev &&
    exec runuser \
      -u dev \
      -- \
      env \
      HOME=/home/dev \
      USER=dev \
      LOGNAME=dev \
      SHELL=/bin/bash \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH="/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin" \
      XDG_RUNTIME_DIR="/run/user/$1" \
      "${@:2}"
  ' _ "$dev_uid" "$@"
}

install_devbox() {
  # "file" (default): the documented file-download path, $0 is a real
  # script path. "pipe": the documented `curl | bash` one-liner, where $0
  # is "bash" - install.sh's own `bash -n "$0"` self-check must guard
  # against that (already fixed in #21) rather than crash the install.
  local invocation="${1:-file}"
  local invoke_installer
  local profile_export=""

  # DEVBOX_REMOTE/DEVBOX_PROFILE come from the calling phase, not from a
  # hardcoded value here, so both phases share this one invocation. An
  # empty profile is left unset so the installer picks its own default.
  if [[ -n "${DEVBOX_E2E_PROFILE}" ]]; then
    profile_export="export DEVBOX_PROFILE='${DEVBOX_E2E_PROFILE}'"
  fi

  if [[ "$invocation" == "pipe" ]]; then
    invoke_installer="curl -fsSL '${INSTALL_URL}' | bash"
  else
    invoke_installer="curl -fsSL '${INSTALL_URL}' -o /tmp/devbox-install.sh && bash /tmp/devbox-install.sh"
  fi

  in_container bash -c "
    set -Eeuo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends curl ca-certificates >/dev/null
    export DEVBOX_REPO_URL='${DEVBOX_REPO_URL}'
    export DEVBOX_REF='${DEVBOX_REF}'
    export DEVBOX_AUTONOMY=balanced
    export DEVBOX_REMOTE='${DEVBOX_E2E_REMOTE}'
    ${profile_export}
    ${invoke_installer}
  "
}

capture_state() {
  {
    in_container cat /var/lib/devbox/version
    in_container cat /var/lib/devbox/installed-features
    as_dev bash -c 'sha256sum ~/.pgpass 2>/dev/null | cut -d" " -f1 || true'
    as_dev bash -c 'cat ~/.codex/config.toml 2>/dev/null || true'
  }
}

launch_container() {
  log "Launching ${CONTAINER} (ubuntu:24.04)"
  lxc launch ubuntu:24.04 "$CONTAINER"

  log "Waiting for network"
  local network_ready=0
  local _

  for _ in $(seq 1 30); do
    if in_container bash -c 'command -v curl >/dev/null 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -y --no-install-recommends curl >/dev/null 2>&1)' &&
      in_container curl -fsS --max-time 5 https://github.com >/dev/null 2>&1; then

      network_ready=1
      break
    fi

    sleep 5
  done

  [[ "$network_ready" -eq 1 ]] || fail "${CONTAINER} never reached the network"
}

# Waits for the container to finish booting after `lxc restart`. The unit
# named here must be a *system* unit whose active state proves the box is
# usable again; `systemctl is-system-running --wait` alone is not enough,
# because it reports failure for a merely degraded boot.
wait_for_boot() {
  local unit="$1"
  local booted=0
  local _

  for _ in $(seq 1 30); do
    if in_container systemctl is-system-running --wait >/dev/null 2>&1 ||
      in_container systemctl is-active --quiet "$unit"; then

      booted=1
      break
    fi

    sleep 5
  done

  [[ "$booted" -eq 1 ]] ||
    fail "${CONTAINER} did not come back up after a restart"
}

####################################################################
# Phase 1: the default remote provider (Happy), full profile
####################################################################

CONTAINER="$CONTAINER_HAPPY"
DEVBOX_E2E_REMOTE="happy"
DEVBOX_E2E_PROFILE=""

launch_container

log "Installing DevBox from ${DEVBOX_REF} (DEVBOX_REMOTE=happy)"
install_devbox

log "devbox doctor"
as_dev devbox doctor

log "Checking agent binaries"
as_dev bash -c 'codex --version' || fail "codex --version failed"
as_dev bash -c 'claude --version' || fail "claude --version failed"
as_dev bash -c 'npm list --global --depth=0 happy' || fail "happy npm package missing"

log "Checking Happy daemon boot service"
in_container systemctl is-enabled --quiet devbox-happy-daemon.service ||
  fail "devbox-happy-daemon.service is not enabled"

# This container is never paired with Happy, so the guard must no-op: the
# unit has to end up clean (active/exited), never failed (issue #19).
in_container systemctl is-failed --quiet devbox-happy-daemon.service &&
  fail "devbox-happy-daemon.service failed on an unpaired box"

log "Rebooting to verify the service survives a restart"
lxc restart "$CONTAINER"
wait_for_boot devbox-happy-daemon.service

in_container systemctl is-active --quiet devbox-happy-daemon.service ||
  fail "devbox-happy-daemon.service is not active after a reboot"

in_container systemctl is-failed --quiet devbox-happy-daemon.service &&
  fail "devbox-happy-daemon.service failed after a reboot"

log "Checking PostgreSQL connection"
as_dev bash -c '
  psql --host 127.0.0.1 --username dev --dbname devbox --no-password \
    --command "SELECT 1;"
' || fail "PostgreSQL connection check failed"

log "Creating Phoenix test project"
as_dev bash -c 'cd ~/workspace && mix phx.new e2e_test --no-install' ||
  fail "mix phx.new failed"

log "DB read/write check (migration stand-in)"
# shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -c` shell, not here
as_dev bash -c '
  set -Eeuo pipefail
  set -a
  source ~/.config/devbox/postgres.env
  set +a
  psql --no-password --command "CREATE TABLE e2e_check (id serial PRIMARY KEY, checked_at timestamptz);"
  psql --no-password --command "INSERT INTO e2e_check (checked_at) VALUES (now());"
  row_count="$(psql --no-password --tuples-only --no-align --command "SELECT count(*) FROM e2e_check;")"
  [[ "$row_count" == "1" ]]
  psql --no-password --command "DROP TABLE e2e_check;"
' || fail "DB read/write check failed"

log "Capturing state before reinstall"
state_before="$(capture_state)"

log "Re-running installer via curl | bash (idempotency + pipe-invocation check)"
install_devbox pipe

log "Capturing state after reinstall"
state_after="$(capture_state)"

if [[ "$state_before" != "$state_after" ]]; then
  printf 'Before:\n%s\n\nAfter:\n%s\n' "$state_before" "$state_after" >&2
  fail "Persistent state changed across a re-install (version/features/pgpass/codex config must be stable)"
fi

log "devbox doctor (after reinstall)"
as_dev devbox doctor

log "Phase 1 (happy) passed"

####################################################################
# Phase 2: DEVBOX_REMOTE=openchamber, minimal profile
####################################################################

CONTAINER="$CONTAINER_OPENCHAMBER"
DEVBOX_E2E_REMOTE="openchamber"
# elixir/postgres are phase 1's job; skipping them here keeps the second
# container cheap (OpenCode alone unpacks a ~180 MB platform binary).
DEVBOX_E2E_PROFILE="minimal"

launch_container

log "Installing DevBox from ${DEVBOX_REF} (DEVBOX_REMOTE=openchamber)"
install_devbox

# A box that has never been through `devbox auth login` has no OpenChamber
# unit and no OpenCode credentials yet. That is the expected state of a
# fresh install, so doctor must report it without failing - the same
# distinction Kisuke needed (#69/#70). install.sh runs doctor itself at the
# end, so a regression here would already have aborted the install above;
# this re-runs it explicitly to pin the guarantee.
log "devbox doctor (fresh, not yet configured)"
as_dev devbox doctor || fail "devbox doctor failed on a fresh OpenChamber box"

log "Checking OpenChamber and OpenCode packages"
as_dev bash -c 'npm list --global --depth=0 @openchamber/web' ||
  fail "@openchamber/web npm package missing"
as_dev bash -c 'npm list --global --depth=0 @opencode/cli' ||
  fail "@opencode/cli npm package missing"

# Both packages ship a stub binary that their postinstall hook replaces
# with the real platform build. `npm list` cannot tell the two apart, so
# run each one: a skipped postinstall shows up here and nowhere else.
as_dev bash -c 'openchamber --version' || fail "openchamber --version failed"
as_dev bash -c 'opencode --version' || fail "opencode --version failed"

# The superseded opencode-ai package claims the same `opencode` bin name;
# having it installed at all means the pin regressed.
if as_dev bash -c 'npm list --global --depth=0 opencode-ai' >/dev/null 2>&1; then
  fail "opencode-ai is installed; OpenChamber needs @opencode/cli (OpenCode 2.x)"
fi

log "Checking the generated UI password"
# shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -c` shell, not here
as_dev bash -c '
  set -Eeuo pipefail
  env_file="$HOME/.config/devbox/openchamber.env"
  [[ -f "$env_file" ]]
  [[ "$(stat -c "%a" "$env_file")" == "600" ]]
  [[ "$(stat -c "%U" "$env_file")" == "dev" ]]
  grep -q "^OPENCHAMBER_HOST=127.0.0.1$" "$env_file"
  grep -q "^OPENCHAMBER_PORT=3000$" "$env_file"
  [[ "$(sed -n "s/^OPENCHAMBER_UI_PASSWORD=//p" "$env_file")" =~ ^[0-9a-f]{48}$ ]]
' || fail "OpenChamber UI password was not generated correctly"

log "Checking the lingering user session"
[[ "$(in_container loginctl show-user dev --property=Linger --value)" == "yes" ]] ||
  fail "loginctl linger is not enabled for dev"

log "Checking version and remote-info output"
as_dev bash -c 'devbox version | grep -q "^OpenChamber:"' ||
  fail "devbox version does not report OpenChamber"
as_dev bash -c 'devbox version --json | jq -e ".openchamber and .opencode" >/dev/null' ||
  fail "devbox version --json does not report OpenChamber/OpenCode"
as_dev bash -c 'devbox remote-info | grep -q "OpenChamber agent workspace"' ||
  fail "devbox remote-info does not render the OpenChamber section"

# This is the point of the whole phase. `devbox auth login` cannot run here
# (it signs Codex and Claude in interactively first), so this invokes the
# same `openchamber startup enable` call its openchamber_auth_login hook
# makes - test-devbox.sh pins that command string, and this proves the
# command works on a real box: the lingering session is reachable, the unit
# gets written, and OpenChamber accepts the installed OpenCode.
log "Enabling the OpenChamber startup service"
# shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -c` shell, not here
as_dev_session bash -c '
  set -Eeuo pipefail
  set -a
  source "$HOME/.config/devbox/openchamber.env"
  set +a
  openchamber startup enable \
    --host "$OPENCHAMBER_HOST" \
    --port "$OPENCHAMBER_PORT" \
    --ui-password "$OPENCHAMBER_UI_PASSWORD"
' || fail "openchamber startup enable failed"

as_dev_session bash -c 'systemctl --user is-enabled --quiet openchamber' ||
  fail "the openchamber systemd --user unit is not enabled"

# OpenChamber serves /health as soon as its own HTTP listener is up, but
# isOpenCodeReady only flips once it has launched and reached the managed
# OpenCode server - which is exactly the compatibility we are testing, and
# takes a while on a cold container.
wait_for_openchamber() {
  local waited=0
  local health=""

  while (( waited < 240 )); do
    health="$(in_container curl -fsS --max-time 5 "$OPENCHAMBER_HEALTH_URL" 2>/dev/null || true)"

    if [[ -n "$health" ]] &&
      printf '%s' "$health" | jq -e '.isOpenCodeReady == true' >/dev/null 2>&1; then

      printf '%s' "$health"
      return 0
    fi

    sleep 5
    waited=$((waited + 5))
  done

  printf '%s' "$health"
  return 1
}

log "Waiting for OpenChamber to report a healthy managed OpenCode"
if ! health="$(wait_for_openchamber)"; then
  printf 'Last /health response: %s\n' "${health:-<none>}" >&2
  as_dev_session bash -c 'journalctl --user-unit openchamber --no-pager -n 40' >&2 2>/dev/null || true
  fail "OpenChamber did not reach isOpenCodeReady (check the pinned OpenCode version)"
fi

printf '%s' "$health" | jq -e '.openchamberVersion and .openCodeRunning == true' >/dev/null ||
  fail "OpenChamber /health did not report a running OpenCode"

log "OpenChamber health: $(printf '%s' "$health" | jq -c '{openchamberVersion, openCodeRunning, isOpenCodeReady}')"

# The unit is a systemd --user service, so this is the real test of the
# lingering session the installer sets up: without it, nothing restarts the
# server until someone logs in interactively.
# openchamber.service is a systemd --user unit, so the system-level signal
# that it can have started at all is dev's lingering user manager.
log "Rebooting to verify OpenChamber comes back without an interactive login"
lxc restart "$CONTAINER"
wait_for_boot "user@$(in_container id -u dev).service"

if ! health="$(wait_for_openchamber)"; then
  printf 'Last /health response: %s\n' "${health:-<none>}" >&2
  fail "OpenChamber did not come back after a reboot (lingering session?)"
fi

log "Checking that a re-install keeps the UI password"
password_before="$(
  # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -c` shell, not here
  as_dev bash -c 'sed -n "s/^OPENCHAMBER_UI_PASSWORD=//p" "$HOME/.config/devbox/openchamber.env"'
)"

install_devbox pipe

password_after="$(
  # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -c` shell, not here
  as_dev bash -c 'sed -n "s/^OPENCHAMBER_UI_PASSWORD=//p" "$HOME/.config/devbox/openchamber.env"'
)"

[[ -n "$password_before" && "$password_before" == "$password_after" ]] ||
  fail "The OpenChamber UI password changed across a re-install"

log "devbox doctor (after reinstall)"
as_dev devbox doctor

log "Phase 2 (openchamber) passed"

log "All checks passed"

