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
# Exercises: fresh install, devbox doctor, agent CLIs, PostgreSQL access, a
# real `mix phx.new` (Elixir/Phoenix toolchain), and - the most important
# single check per issue #10 - that re-running the installer is idempotent:
# persistent state (version, features, the PostgreSQL password, an existing
# ~/.codex/config.toml) must come out unchanged.

set -Eeuo pipefail

DEVBOX_REPO_URL="${DEVBOX_REPO_URL:-https://raw.githubusercontent.com/c4kingpin/Scripts}"
DEVBOX_REF="${DEVBOX_REF:-master}"
readonly DEVBOX_REPO_URL DEVBOX_REF

readonly CONTAINER="devbox-e2e-$$"
readonly INSTALL_URL="${DEVBOX_REPO_URL%/}/${DEVBOX_REF}/devbox/install.sh"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nFAILED: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  lxc delete --force "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

in_container() {
  lxc exec "$CONTAINER" -- "$@"
}

as_dev() {
  # Mirrors run_as_dev() in devbox/lib/common.sh (runuser with an explicit
  # dev-shaped environment, not sudo - dev has no generic sudo access, see
  # P0.1), so this test exercises the same invocation shape DevBox itself
  # relies on.
  lxc exec "$CONTAINER" -- \
    runuser \
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
}

install_devbox() {
  in_container bash -c "
    set -Eeuo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends curl ca-certificates >/dev/null
    export DEVBOX_REPO_URL='${DEVBOX_REPO_URL}'
    export DEVBOX_REF='${DEVBOX_REF}'
    export DEVBOX_AUTONOMY=balanced
    curl -fsSL '${INSTALL_URL}' -o /tmp/devbox-install.sh
    bash /tmp/devbox-install.sh
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

log "Launching ${CONTAINER} (ubuntu:24.04)"
lxc launch ubuntu:24.04 "$CONTAINER"

log "Waiting for network"
network_ready=0
for _ in $(seq 1 30); do
  if in_container bash -c 'command -v curl >/dev/null 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -y --no-install-recommends curl >/dev/null 2>&1)' &&
    in_container curl -fsS --max-time 5 https://github.com >/dev/null 2>&1; then

    network_ready=1
    break
  fi

  sleep 5
done

[[ "$network_ready" -eq 1 ]] || fail "Container never reached the network"

log "Installing DevBox from ${DEVBOX_REF}"
install_devbox

log "devbox doctor"
as_dev devbox doctor

log "Checking agent binaries"
as_dev bash -c 'codex --version' || fail "codex --version failed"
as_dev bash -c 'claude --version' || fail "claude --version failed"
as_dev bash -c 'npm list --global --depth=0 happy' || fail "happy npm package missing"

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

log "Re-running installer (idempotency check)"
install_devbox

log "Capturing state after reinstall"
state_after="$(capture_state)"

if [[ "$state_before" != "$state_after" ]]; then
  printf 'Before:\n%s\n\nAfter:\n%s\n' "$state_before" "$state_after" >&2
  fail "Persistent state changed across a re-install (version/features/pgpass/codex config must be stable)"
fi

log "devbox doctor (after reinstall)"
as_dev devbox doctor

log "All checks passed"
