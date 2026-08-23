#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly DEV_USER="dev"
readonly DEV_HOME="/home/${DEV_USER}"
readonly WORKSPACE_DIR="${DEV_HOME}/workspace"

readonly STATE_DIR="${DEV_HOME}/.config/devbox"
readonly ONBOARDING_MARKER="${STATE_DIR}/onboarding-complete"

# Root-owned DevBox state (P1.4): active/previous version, installed
# features, install metadata. Readable by dev (doctor runs without root),
# written only by root (update/rollback/install.sh all require_root).
readonly ROOT_STATE_DIR="/var/lib/devbox"
readonly FEATURES_FILE="${ROOT_STATE_DIR}/installed-features"
readonly ROOT_VERSION_FILE="${ROOT_STATE_DIR}/version"
readonly PREVIOUS_VERSION_FILE="${ROOT_STATE_DIR}/previous-version"
readonly PREVIOUS_REF_FILE="${ROOT_STATE_DIR}/previous-ref"
readonly ACTIVE_REF_FILE="${ROOT_STATE_DIR}/active-ref"
readonly REMOTE_PROVIDER_FILE="${ROOT_STATE_DIR}/remote-provider"
readonly ROOT_COMMIT_FILE="${ROOT_STATE_DIR}/commit"
readonly INSTALL_STATE_FILE="${ROOT_STATE_DIR}/install-state.json"

readonly SSH_CONFIG="/etc/ssh/sshd_config.d/00-devbox.conf"
readonly SSH_KEY_FILE="${DEV_HOME}/.ssh/authorized_keys.devbox"
readonly SSH_STANDARD_KEY_FILE="${DEV_HOME}/.ssh/authorized_keys"
readonly SSH_DISABLED_MARKER="${STATE_DIR}/ssh-disabled"

readonly HAPPY_HOME="${DEV_HOME}/.happy"
readonly HAPPY_ACCESS_KEY="${HAPPY_HOME}/access.key"
readonly HAPPY_SETTINGS="${HAPPY_HOME}/settings.json"
readonly HAPPY_DAEMON_STATE="${HAPPY_HOME}/daemon.state.json"

# Boot-time Happy daemon start (issue #19), installed by
# devbox/features/happy.sh.
readonly HAPPY_SERVICE="devbox-happy-daemon.service"
readonly HAPPY_SERVICE_UNIT="/etc/systemd/system/${HAPPY_SERVICE}"

# #43: Kisuke Connect, an alternative to Happy as DEVBOX_REMOTE. Kisuke
# manages its own boot-time service - a systemd --user unit named "kisuke",
# installed by `kisuke connect`/`kisuke install` itself (not by DevBox).
# DevBox's only Kisuke-specific boot-time setup is enabling a lingering user
# session (devbox/features/kisuke.sh) so `systemctl --user` has a D-Bus bus
# to talk to before anyone has ever logged in interactively.
readonly KISUKE_HOME="${DEV_HOME}/.kisuke"
readonly KISUKE_SERVICE="kisuke"
readonly MULTICA_HOME="${DEV_HOME}/.multica"
readonly MULTICA_SERVICE="devbox-multica-daemon.service"
readonly MULTICA_SERVICE_UNIT="/etc/systemd/system/${MULTICA_SERVICE}"
readonly MULTICA_SELF_HOST_URL="http://127.0.0.1:3000"
readonly MULTICA_SELF_HOST_HEALTH_URL="http://127.0.0.1:8080/healthz"
readonly MULTICA_PUBLIC_CONFIG_FILE="${ROOT_STATE_DIR}/multica-public.env"

readonly OPENROUTER_ENV="${STATE_DIR}/openrouter.env"
readonly OPENROUTER_PROFILE="${DEV_HOME}/.codex/openrouter.config.toml"
readonly OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex-openrouter"
readonly LEGACY_OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex"

readonly NODE_MAJOR="24"

# Mirrors the version manifest embedded in install.sh / devbox/versions.env.
readonly DEVBOX_VERSION="1.5.0-RC4"
readonly ERLANG_VERSION="29.0.5"
readonly ELIXIR_VERSION="1.20.3"
readonly PHOENIX_VERSION="1.8.9"
readonly CODEX_VERSION="0.147.0"
readonly CLAUDE_VERSION="2.1.233"
readonly HAPPY_VERSION="1.2.0"
readonly KISUKE_VERSION="1.2.20"
readonly MULTICA_VERSION="0.4.32"

readonly PACKAGE_NAME_PATTERN='^[a-z0-9][a-z0-9+.-]*$'

readonly DEFAULT_REPO_URL="https://raw.githubusercontent.com/c4kingpin/Scripts"
readonly DEFAULT_GITHUB_REPO="c4kingpin/Scripts"

# P1.3 briefly recorded this under the user-state directory, before
# ROOT_STATE_DIR existed; record_previous_update_state() migrates it once.
readonly LEGACY_PREVIOUS_UPDATE_FILE="${STATE_DIR}/previous-update.env"

info() {
  printf '==> %s\n' "$*"
}

ok() {
  printf 'ok - %s\n' "$*"
}

warn() {
  printf 'warning - %s\n' "$*" >&2
}

die() {
  printf 'error - %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: devbox COMMAND [SUBCOMMAND]

Commands:

  onboard
      Run interactive first-login onboarding.

  ssh status
      Show SSH status for the dev user.

  ssh setup
      Configure public-key SSH login for dev only.

  ssh disable
      Disable SSH login for dev only.

  packages list
      List installed OS packages.

  packages install <package...>
      Install OS packages via a controlled, validated apt-get call.
      Requires root (sudo devbox packages install <package...>).

  version
      Show centrally managed DevBox tool versions.

  version --json
      Same as version, as a JSON object.

  auth status
      Show Codex, Claude and remote-provider (Happy/Kisuke/Multica) authentication
      status.

  auth login
      Authenticate Codex and Claude, then pair/authenticate and start the
      configured remote provider (Happy, Kisuke or Multica).

  auth logout
      Sign out of Codex, Claude and the configured remote provider.

  openrouter status
      Show OpenRouter fallback configuration.

  openrouter setup
      Configure codex-openrouter as explicit fallback.

  openrouter disable
      Remove managed OpenRouter configuration.

  github status
      Show GitHub authentication and Git identity.

  github setup
      Configure GitHub authentication and Git identity.

  keys status
      Show outbound DevBox SSH identity key.

  keys generate
      Generate an outbound Ed25519 identity key.

  keys upload-github
      Upload the identity key to GitHub.

  remote-info
      Explain the configured remote provider (Happy, Kisuke, Multica, or none).

  status
      Show how this box is configured: version, profile, features,
      SSH, agent auth, GitHub and OpenRouter.

  workspace list
      List project directories under the dev workspace.

  workspace doctor <project>
      Read-only checks for one workspace project (Git repo, .env present).

  doctor
      Validate the development environment.

  doctor --json
      Same checks as doctor, as a machine-readable JSON summary.
      Exit code 0 means healthy, 1 means unhealthy.

  update [--check] [--to TAG] [--branch NAME]
      Update DevBox. Default: the latest published release.
      --check        Report an available update without installing it.
      --to TAG       Update to a specific release tag (e.g. v1.1.0).
      --branch NAME  Update from a branch instead of a release (testing).
      A bare branch name (devbox update NAME) is a shorthand for --branch.

  rollback
      Re-run the installer for the ref that was active before the last
      update. Only reinstalls DevBox itself; OS package upgrades,
      PostgreSQL data and workspace changes are not reverted.

  help
      Show this help.
EOF
}

require_root() {
  [[ "$EUID" -eq 0 ]] ||
    die "This command must run as root."
}

require_dev() {
  [[ "$EUID" -ne 0 &&
     "$(id -un)" == "$DEV_USER" ]] ||
    die "Run this command as ${DEV_USER}."
}

run_as_dev() {
  if [[ "$EUID" -eq 0 ]]; then
    (
      cd "$DEV_HOME"

      # XDG_RUNTIME_DIR is required for `systemctl --user` (used by the
      # Kisuke remote-provider checks) to find dev's D-Bus user session when
      # invoked from a root shell via runuser, rather than an actual login.
      exec runuser \
        -u "$DEV_USER" \
        -- \
        env \
          HOME="$DEV_HOME" \
          USER="$DEV_USER" \
          LOGNAME="$DEV_USER" \
          SHELL="/bin/bash" \
          LANG="C.UTF-8" \
          LC_ALL="C.UTF-8" \
          PATH="${DEV_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
          XDG_RUNTIME_DIR="/run/user/$(id -u "$DEV_USER")" \
          "$@"
    )
  else
    LANG="C.UTF-8" \
    LC_ALL="C.UTF-8" \
    "$@"
  fi
}

# P0.1: dev owns everything under $DEV_HOME, so a root-executed command
# that blindly creates/writes into a dev-controlled path can be redirected
# by a symlink dev planted there in advance. Reject that outright instead
# of following it.
reject_symlink() {
  local path="$1"

  [[ ! -L "$path" ]] ||
    die "Refusing to operate on ${path}: it is a symlink"
}

# Writes $content to $target atomically and symlink-safely: rejects an
# existing symlink or other non-regular-file target, then writes via a
# same-directory tempfile and renames it into place (rename() replaces a
# symlink at the destination rather than following it, so even a target
# re-created between the check above and this write can't redirect the
# write outside $target's directory).
write_root_owned_file() {
  local target="$1"
  local mode="$2"
  local content="$3"
  local tmp

  reject_symlink "$target"

  [[ ! -e "$target" || -f "$target" ]] ||
    die "Refusing to write ${target}: exists but is not a regular file"

  tmp="$(mktemp "${target}.XXXXXX")"

  printf '%s' "$content" >"$tmp"

  chown "${DEV_USER}:${DEV_USER}" "$tmp"
  chmod "$mode" "$tmp"

  mv -f "$tmp" "$target"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-yes}"
  local answer=""

  if [[ "$default" == "yes" ]]; then
    read -r \
      -p "${prompt} [Y/n] " \
      answer \
      || answer="n"

    [[ -z "$answer" ||
       "${answer,,}" =~ ^(y|yes|j|ja)$ ]]
  else
    read -r \
      -p "${prompt} [y/N] " \
      answer \
      || answer="n"

    [[ "${answer,,}" =~ ^(y|yes|j|ja)$ ]]
  fi
}

ensure_sshd_runtime() {
  install \
    -d \
    -m 0755 \
    /run/sshd
}

validate_public_key() {
  local key="$1"
  local key_file
  local status

  [[ -n "$key" &&
     "$key" != *$'\n'* &&
     "$key" != *$'\r'* ]] ||
    return 1

  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] ||
    return 1

  key_file="$(mktemp)"

  chmod \
    0600 \
    "$key_file"

  printf '%s\n' \
    "$key" \
    >"$key_file"

  if ssh-keygen \
    -l \
    -f "$key_file" \
    >/dev/null 2>&1; then

    status=0
  else
    status=$?
  fi

  rm -f "$key_file"

  return "$status"
}

write_dev_ssh_policy() {
  require_root

  local mode="${1:-enabled}"

  install \
    -d \
    -m 0755 \
    /etc/ssh/sshd_config.d

  case "$mode" in
    enabled)
      cat <<'EOF' >"$SSH_CONFIG"
# Managed by DevBox.
# Applies only to user "dev". Root/admin SSH policy is untouched.

Match User dev
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys.devbox

Match all
EOF
      ;;

    disabled)
      cat <<'EOF' >"$SSH_CONFIG"
# Managed by DevBox.
# Disable SSH login for user "dev" only.
# Root/admin SSH policy is untouched.

DenyUsers dev
EOF
      ;;

    *)
      die "Unknown SSH policy mode: ${mode}"
      ;;
  esac

  chmod \
    0644 \
    "$SSH_CONFIG"

  ensure_sshd_runtime

  /usr/sbin/sshd -t
}

apply_sshd_config() {
  require_root

  local activate_if_inactive="${1:-no}"

  ensure_sshd_runtime

  /usr/sbin/sshd -t

  if systemctl is-active \
    --quiet \
    ssh.service; then

    systemctl reload ssh.service

  elif systemctl is-active \
    --quiet \
    ssh.socket; then

    :

  elif [[ "$activate_if_inactive" == "yes" ]]; then

    systemctl enable \
      --now \
      ssh.service
  fi
}

ssh_status() {
  local listener_status="inactive"
  local dev_policy="unmanaged"
  local managed_key="not configured"
  local standard_key="not configured"

  if systemctl is-active \
    --quiet \
    ssh.service \
    || systemctl is-active \
      --quiet \
      ssh.socket; then

    listener_status="active"
  fi

  if [[ -f "$SSH_CONFIG" ]]; then
    if grep \
      -Eq \
      '^DenyUsers[[:space:]]+dev([[:space:]]|$)' \
      "$SSH_CONFIG"; then

      dev_policy="disabled"

    elif grep \
      -Eq \
      '^Match[[:space:]]+User[[:space:]]+dev([[:space:]]|$)' \
      "$SSH_CONFIG"; then

      dev_policy="public-key only"
    fi
  fi

  [[ -s "$SSH_KEY_FILE" ]] &&
    managed_key="configured"

  [[ -s "$SSH_STANDARD_KEY_FILE" ]] &&
    standard_key="configured"

  printf 'SSH listener: %s\n' \
    "$listener_status"

  printf 'DevBox dev-user SSH policy: %s\n' \
    "$dev_policy"

  printf 'Managed DevBox key: %s\n' \
    "$managed_key"

  printf 'Standard dev authorized_keys: %s\n' \
    "$standard_key"

  printf 'Administrative/root SSH policy: untouched by DevBox\n'

  if [[ -s "$SSH_KEY_FILE" ]]; then
    printf '\nManaged DevBox SSH key:\n'

    ssh-keygen \
      -l \
      -f "$SSH_KEY_FILE"
  fi
}

ssh_setup() {
  require_root

  [[ -t 0 && -t 1 ]] ||
    die "SSH setup requires an interactive terminal."

  cat <<'EOF'
Configure SSH access for the "dev" account.

This does NOT modify or disable administrative/root SSH access.

Paste only the client's public .pub key.
Never copy a private key here.
EOF

  local public_key=""

  read -r \
    -p "Client public key: " \
    public_key

  validate_public_key "$public_key" ||
    die "The public key is invalid."

  reject_symlink "${DEV_HOME}/.ssh"

  install \
    -d \
    -m 0700 \
    -o "$DEV_USER" \
    -g "$DEV_USER" \
    "${DEV_HOME}/.ssh"

  write_root_owned_file \
    "$SSH_KEY_FILE" \
    0600 \
    "${public_key}"$'\n'

  rm \
    -f \
    "$SSH_DISABLED_MARKER"

  write_dev_ssh_policy enabled
  apply_sshd_config yes

  ok "SSH public-key login enabled for ${DEV_USER}"
  ok "Administrative/root SSH policy was not changed"

  ssh-keygen \
    -l \
    -f "$SSH_KEY_FILE"
}

ssh_disable() {
  require_root

  reject_symlink "$STATE_DIR"

  install \
    -d \
    -m 0700 \
    -o "$DEV_USER" \
    -g "$DEV_USER" \
    "$STATE_DIR"

  write_root_owned_file \
    "$SSH_DISABLED_MARKER" \
    0600 \
    ""

  write_dev_ssh_policy disabled
  apply_sshd_config no

  ok "SSH login disabled for ${DEV_USER}"
  ok "Administrative/root SSH policy was not changed"
}

validate_package_name() {
  local package="$1"

  [[ "$package" =~ $PACKAGE_NAME_PATTERN ]]
}

packages_list() {
  dpkg-query \
    --show \
    --showformat '${Package}\t${Version}\n' \
  | sort
}

packages_install() {
  require_root

  local package
  local packages=("$@")

  [[ "${#packages[@]}" -gt 0 ]] ||
    die "Usage: devbox packages install <package...>"

  for package in "${packages[@]}"; do
    validate_package_name "$package" ||
      die "Refusing invalid package name: ${package}"
  done

  info "Installing packages: ${packages[*]}"

  DEBIAN_FRONTEND=noninteractive \
    apt-get install \
      -y \
      --no-install-recommends \
      -- \
      "${packages[@]}"

  ok "Installed packages: ${packages[*]}"
}

# P2.1: DEVBOX_VERSION alone doesn't uniquely identify installed code -
# master can move between releases while the version string stays the
# same. The installed commit (persisted by install.sh, P1.3) disambiguates
# that; "unknown" for installs from before P1.3 rather than a guess.
installed_commit() {
  if [[ -r "$ROOT_COMMIT_FILE" ]]; then
    printf '%s' "$(<"$ROOT_COMMIT_FILE")"
  else
    printf 'unknown'
  fi
}

show_version() {
  cat <<EOF
DevBox:        ${DEVBOX_VERSION}
Commit:        $(installed_commit)
Node:          ${NODE_MAJOR}
Erlang:        ${ERLANG_VERSION}
Elixir:        ${ELIXIR_VERSION}
Phoenix:       ${PHOENIX_VERSION}
Codex CLI:     ${CODEX_VERSION}
Claude Code:   ${CLAUDE_VERSION}
Happy:         ${HAPPY_VERSION}
Kisuke:        ${KISUKE_VERSION}
Multica:       ${MULTICA_VERSION}
EOF
}

show_version_json() {
  jq \
    -n \
    --arg devbox "$DEVBOX_VERSION" \
    --arg commit "$(installed_commit)" \
    --arg node "$NODE_MAJOR" \
    --arg erlang "$ERLANG_VERSION" \
    --arg elixir "$ELIXIR_VERSION" \
    --arg phoenix "$PHOENIX_VERSION" \
    --arg codex_cli "$CODEX_VERSION" \
    --arg claude_code "$CLAUDE_VERSION" \
    --arg happy "$HAPPY_VERSION" \
    --arg kisuke "$KISUKE_VERSION" \
    --arg multica "$MULTICA_VERSION" \
    '{
      devbox: $devbox,
      commit: $commit,
      node: $node,
      erlang: $erlang,
      elixir: $elixir,
      phoenix: $phoenix,
      codex_cli: $codex_cli,
      claude_code: $claude_code,
      happy: $happy,
      kisuke: $kisuke,
      multica: $multica
    }'
}

codex_is_authenticated() {
  codex login status \
    >/dev/null 2>&1
}

claude_is_authenticated() {
  claude auth status \
    >/dev/null 2>&1
}

happy_is_authenticated() {
  [[ -s "$HAPPY_ACCESS_KEY" ]] ||
    return 1

  [[ -s "$HAPPY_SETTINGS" ]] ||
    return 1

  jq \
    -e \
    '
      (.machineId? | type == "string")
      and
      (.machineId | length > 0)
    ' \
    "$HAPPY_SETTINGS" \
    >/dev/null 2>&1
}

happy_daemon_service_is_installed() {
  [[ -f "$HAPPY_SERVICE_UNIT" ]]
}

happy_daemon_service_is_enabled() {
  systemctl is-enabled \
    --quiet \
    "$HAPPY_SERVICE" \
    2>/dev/null
}

happy_daemon_is_running() {
  local pid=""

  [[ -s "$HAPPY_DAEMON_STATE" ]] ||
    return 1

  pid="$(
    jq \
      -r \
      '.pid // empty' \
      "$HAPPY_DAEMON_STATE" \
      2>/dev/null \
      || true
  )"

  [[ "$pid" =~ ^[0-9]+$ ]] ||
    return 1

  kill \
    -0 \
    "$pid" \
    2>/dev/null
}

harden_happy_state() {
  install \
    -d \
    -m 0700 \
    "$HAPPY_HOME"

  chmod \
    0700 \
    "$HAPPY_HOME"

  local path

  for path in \
    "$HAPPY_ACCESS_KEY" \
    "$HAPPY_SETTINGS" \
    "${HAPPY_HOME}/sessions.json" \
    "$HAPPY_DAEMON_STATE"; do

    if [[ -f "$path" ]]; then
      chmod \
        0600 \
        "$path"
    fi
  done
}

# Remote-provider hook (DEVBOX_REMOTE=happy), dispatched generically by
# agents_auth_status() - see devbox/README.md, "Neuen Remote-Provider
# hinzufügen". Returns non-zero only for "not paired", matching the status
# semantics agents_auth_status() folds into its own exit code; the daemon/
# boot-service checks below are informational and never affect it.
happy_auth_status() {
  local status=0

  if happy_is_authenticated; then
    ok "Happy is authenticated and this DevBox is registered"
  else
    warn "Happy is not paired"
    status=1
  fi

  if happy_is_authenticated; then
    if happy_daemon_is_running; then
      ok "Happy daemon is running"
    else
      warn "Happy daemon is not running"
    fi
  fi

  if happy_daemon_service_is_installed &&
    happy_daemon_service_is_enabled; then

    ok "Happy daemon starts automatically at boot (${HAPPY_SERVICE})"
  else
    warn "Happy daemon does not start at boot; run 'devbox update' as root"
  fi

  return "$status"
}

# Remote-provider hook: pairs/starts Happy during `devbox auth login`.
happy_auth_login() {
  if happy_is_authenticated; then
    ok "Happy is already paired"
  else
    info "Pairing this DevBox with Happy"
    info "Happy asking you to connect/pair at this point is expected."

    happy auth login
  fi

  harden_happy_state

  if happy_is_authenticated; then
    if happy_daemon_is_running; then
      ok "Happy daemon is already running"
    else
      info "Starting Happy daemon"

      if happy daemon start \
        >/dev/null 2>&1; then

        ok "Happy daemon started"
      else
        warn "Happy daemon could not be started; run: happy daemon start"
      fi
    fi
  fi
}

# Remote-provider hook: signs Happy out during `devbox auth logout`.
happy_auth_logout() {
  if happy_daemon_is_running; then
    happy daemon stop \
      || warn "Happy daemon stop reported an error"
  fi

  if happy_is_authenticated; then
    if [[ -t 0 && -t 1 ]]; then
      happy auth logout \
        || warn "Happy logout reported an error"
    else
      warn "Happy logout requires an interactive terminal and was skipped"
    fi
  else
    ok "Happy is already signed out"
  fi
}

# Kisuke's on-disk state (~/.kisuke: auth_token, kisuke.db, ...) isn't a
# documented format the way Happy's access.key/settings.json are, so -
# unlike happy_is_authenticated() - this shells out to the CLI itself
# (matching how codex_is_authenticated()/claude_is_authenticated() work)
# rather than inferring state from files.
kisuke_is_authenticated() {
  run_as_dev kisuke whoami \
    >/dev/null 2>&1
}

# `systemctl list-unit-files` exits 0 with an empty result for an unknown
# unit name, so this uses `cat` instead - it fails when there is no unit
# file to display at all, which is the actual "installed?" question.
# shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
kisuke_daemon_service_is_installed() {
  run_as_dev \
    bash \
    -lc \
    'systemctl --user cat "$1" >/dev/null 2>&1' \
    _ \
    "${KISUKE_SERVICE}.service"
}

# shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
kisuke_daemon_service_is_enabled() {
  run_as_dev \
    bash \
    -lc \
    'systemctl --user is-enabled --quiet "$1"' \
    _ \
    "$KISUKE_SERVICE"
}

# shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
kisuke_daemon_is_running() {
  run_as_dev \
    bash \
    -lc \
    'systemctl --user is-active --quiet "$1"' \
    _ \
    "$KISUKE_SERVICE"
}

# Kisuke manages the permissions of its own state files; DevBox only
# tightens the directory itself, the same defense-in-depth it applies to
# ~/.happy, without guessing at which specific file inside holds the
# account credential.
harden_kisuke_state() {
  install \
    -d \
    -m 0700 \
    "$KISUKE_HOME"

  chmod \
    0700 \
    "$KISUKE_HOME"
}

# Remote-provider hook (DEVBOX_REMOTE=kisuke), dispatched generically by
# agents_auth_status() - see devbox/README.md, "Neuen Remote-Provider
# hinzufügen". Returns non-zero only for "not authenticated", matching the
# status semantics agents_auth_status() folds into its own exit code; the
# daemon/boot-service checks below are informational and never affect it.
kisuke_auth_status() {
  local status=0

  if kisuke_is_authenticated; then
    ok "Kisuke is authenticated and this DevBox is registered"
  else
    warn "Kisuke is not authenticated"
    status=1
  fi

  if kisuke_daemon_is_running; then
    ok "Kisuke daemon is running"
  else
    warn "Kisuke daemon is not running"
  fi

  if kisuke_daemon_service_is_installed &&
    kisuke_daemon_service_is_enabled; then

    ok "Kisuke daemon starts automatically at boot (systemd --user, lingering session)"
  else
    warn "Kisuke daemon service is not installed yet; run: devbox auth login"
  fi

  return "$status"
}

# Remote-provider hook: authenticates Kisuke during `devbox auth login`.
kisuke_auth_login() {
  if kisuke_is_authenticated; then
    ok "Kisuke is already authenticated"
  else
    info "Setting up Kisuke Connect"
    info "Kisuke prints a URL to open on another device; no local browser is needed."

    # `kisuke connect` is the guided setup path: it installs and starts
    # Kisuke's own systemd --user service (which enable_kisuke_user_linger
    # made reachable at install time) and completes login in one command -
    # it also no-ops cleanly if already set up, so this is safe to run
    # even when only some of that already happened.
    kisuke connect \
      --headless
  fi

  harden_kisuke_state
}

# Remote-provider hook: signs Kisuke out during `devbox auth logout`.
kisuke_auth_logout() {
  if kisuke_is_authenticated; then
    kisuke logout \
      || warn "Kisuke logout reported an error"
  else
    ok "Kisuke is already signed out"
  fi

  if kisuke_daemon_is_running; then
    # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
    run_as_dev \
      bash \
      -lc \
      'systemctl --user stop "$1"' \
      _ \
      "${KISUKE_SERVICE}.service" \
      || warn "Kisuke daemon stop reported an error"
  fi
}

# Remote-provider hooks for Multica. Its documented CLI is the authority for
# authentication and daemon state; DevBox never reads its token files.
multica_is_authenticated() {
  local auth_status

  # Multica 0.4.x returns success for `auth status` once a server URL is
  # configured, even when no token exists. Inspect its documented status text
  # so `devbox auth login` still enters the headless token flow.
  auth_status="$(multica auth status 2>&1)" || return 1
  [[ "$auth_status" != *"Not authenticated"* && "$auth_status" == *"Authenticated"* ]]
}

multica_daemon_service_is_installed() {
  [[ -f "$MULTICA_SERVICE_UNIT" ]]
}

multica_daemon_service_is_enabled() {
  systemctl is-enabled --quiet "$MULTICA_SERVICE" 2>/dev/null
}

multica_daemon_is_running() {
  multica daemon status >/dev/null 2>&1
}

multica_self_host_is_running() {
  curl -fsS "$MULTICA_SELF_HOST_HEALTH_URL" >/dev/null 2>&1
}

harden_multica_state() {
  [[ -d "$MULTICA_HOME" ]] || return 0
  chmod 0700 "$MULTICA_HOME"
}

multica_configure_public_urls() {
  local app_url=""
  local server_url=""

  [[ -r "$MULTICA_PUBLIC_CONFIG_FILE" ]] || return 1
  app_url="$(awk -F= '$1 == "MULTICA_APP_URL" { print substr($0, index($0, "=") + 1) }' "$MULTICA_PUBLIC_CONFIG_FILE")"
  server_url="$(awk -F= '$1 == "MULTICA_SERVER_URL" { print substr($0, index($0, "=") + 1) }' "$MULTICA_PUBLIC_CONFIG_FILE")"
  [[ -n "$app_url" && -n "$server_url" ]] || return 1

  multica config set server_url "$server_url"
  multica config set app_url "$app_url"
}

multica_public_app_url() {
  [[ -r "$MULTICA_PUBLIC_CONFIG_FILE" ]] || return 1
  awk -F= '$1 == "MULTICA_APP_URL" { print substr($0, index($0, "=") + 1) }' "$MULTICA_PUBLIC_CONFIG_FILE"
}

multica_auth_status() {
  local status=0 self_host_url="$MULTICA_SELF_HOST_URL"

  self_host_url="$(multica_public_app_url || printf '%s' "$MULTICA_SELF_HOST_URL")"

  if multica_is_authenticated; then
    ok "Multica is authenticated and this DevBox is registered"
  else
    warn "Multica is not authenticated"
    status=1
  fi

  if multica_daemon_is_running; then
    ok "Multica daemon is running"
  else
    warn "Multica daemon is not running"
  fi

  if multica_self_host_is_running; then
    ok "Multica self-hosted server is running (${self_host_url})"
  else
    warn "Multica self-hosted server is not running"
  fi

  if multica_daemon_service_is_installed && multica_daemon_service_is_enabled; then
    ok "Multica daemon starts automatically at boot (${MULTICA_SERVICE})"
  else
    warn "Multica daemon does not start at boot; run 'devbox update' as root"
  fi

  return "$status"
}

multica_auth_login() {
  local public_urls_configured=0

  # Reapply public endpoints even when a local session already exists. A
  # reverse-proxy migration must not require deleting a valid token first.
  if multica_configure_public_urls; then
    public_urls_configured=1
  fi

  if multica_is_authenticated; then
    ok "Multica is already authenticated"
  else
    if (( public_urls_configured )); then
      info "Open the reverse-proxied Multica web UI, create a personal API token, then paste it here."
      multica login --token
    else
      info "Configuring the self-hosted Multica server"
      info "Use an SSH tunnel to open ${MULTICA_SELF_HOST_URL} locally if this DevBox has no browser."
      multica setup self-host
    fi
  fi

  harden_multica_state

  if multica_is_authenticated; then
    if multica_daemon_is_running; then
      ok "Multica daemon is already running"
    else
      info "Starting Multica daemon"
      multica daemon start || warn "Multica daemon could not be started; run: multica daemon start"
    fi
  fi
}

multica_auth_logout() {
  if multica_daemon_is_running; then
    multica daemon stop || warn "Multica daemon stop reported an error"
  fi

  if multica_is_authenticated; then
    multica auth logout || warn "Multica logout reported an error"
  else
    ok "Multica is already signed out"
  fi
}

# Remote-provider hooks are dispatched by naming convention -
# "${remote_provider}_auth_status"/"_auth_login"/"_auth_logout" - defined
# next to happy_is_authenticated()/kisuke_is_authenticated() above. Adding a
# provider means adding those three functions under its own name; nothing
# here needs to change. See devbox/README.md, "Neuen Remote-Provider
# hinzufügen".

agents_auth_status() {
  require_dev

  local status=0
  local remote_provider
  remote_provider="$(configured_remote_provider)"

  if codex_is_authenticated; then
    ok "Codex CLI is authenticated"
  else
    warn "Codex CLI is not authenticated"
    status=1
  fi

  if claude_is_authenticated; then
    ok "Claude CLI is authenticated"
  else
    warn "Claude CLI is not authenticated"
    status=1
  fi

  if [[ "$remote_provider" != "none" ]]; then
    "${remote_provider}_auth_status" || status=1
  fi

  return "$status"
}

agents_auth_login() {
  require_dev

  local remote_provider
  remote_provider="$(configured_remote_provider)"

  if codex_is_authenticated; then
    ok "Codex CLI is already authenticated"
  else
    info "Signing in to Codex using the device-code flow"

    codex login \
      --device-auth

    if [[ -f "${HOME}/.codex/auth.json" ]]; then
      chmod \
        0600 \
        "${HOME}/.codex/auth.json"
    fi
  fi

  if claude_is_authenticated; then
    ok "Claude CLI is already authenticated"
  else
    info "Signing in to Claude"

    claude auth login

    if [[ -f "${HOME}/.claude/.credentials.json" ]]; then
      chmod \
        0600 \
        "${HOME}/.claude/.credentials.json"
    fi
  fi

  if [[ "$remote_provider" != "none" ]]; then
    "${remote_provider}_auth_login"
  fi

  agents_auth_status
}

agents_auth_logout() {
  require_dev

  local remote_provider
  remote_provider="$(configured_remote_provider)"

  if [[ "$remote_provider" != "none" ]]; then
    "${remote_provider}_auth_logout"
  fi

  codex logout \
    || warn "Codex logout reported an error"

  claude auth logout \
    || warn "Claude logout reported an error"

  ok "Agent logout completed"
}

is_managed_openrouter_file() {
  local path="$1"

  [[ -f "$path" ]] &&
    head \
      -n 2 \
      "$path" \
    | grep \
      -Eq \
      'Managed by (devbox|codex-devbox) openrouter setup'
}

openrouter_status() {
  require_dev

  local model=""
  local status=0

  if is_managed_openrouter_file "$OPENROUTER_ENV"; then
    ok "OpenRouter API key is stored (value hidden)"
  else
    warn "OpenRouter API key is not configured"
    status=1
  fi

  if is_managed_openrouter_file "$OPENROUTER_PROFILE"; then
    model="$(
      sed \
        -n \
        's/^model = "\(.*\)"$/\1/p' \
        "$OPENROUTER_PROFILE"
    )"

    ok "Codex OpenRouter profile (${model:-unknown model})"
  else
    warn "Codex OpenRouter profile is not configured"
    status=1
  fi

  if is_managed_openrouter_file "$LEGACY_OPENROUTER_WRAPPER"; then
    warn "Legacy setup still routes native codex through OpenRouter"
    status=1

  elif is_managed_openrouter_file "$OPENROUTER_WRAPPER"; then
    ok "OpenRouter fallback command: codex-openrouter"

  else
    warn "OpenRouter fallback command is not configured"
    status=1
  fi

  return "$status"
}

openrouter_setup() {
  require_dev

  [[ -t 0 && -t 1 ]] ||
    die "OpenRouter setup requires an interactive terminal."

  local api_key=""
  local model=""
  local path

  for path in \
    "$OPENROUTER_ENV" \
    "$OPENROUTER_PROFILE" \
    "$OPENROUTER_WRAPPER"; do

    if [[ -e "$path" ]] &&
      ! is_managed_openrouter_file "$path"; then

      die "Refusing to overwrite unmanaged file: ${path}"
    fi
  done

  read -r \
    -s \
    -p "OpenRouter API key: " \
    api_key

  printf '\n'

  [[ "$api_key" == sk-or-* ]] ||
    die "The API key must start with sk-or-."

  read -r \
    -p "OpenRouter model [~openai/gpt-latest]: " \
    model

  model="${model:-~openai/gpt-latest}"

  [[ "$model" =~ ^[A-Za-z0-9._~:/-]+$ ]] ||
    die "Invalid OpenRouter model ID."

  if is_managed_openrouter_file "$LEGACY_OPENROUTER_WRAPPER"; then
    rm \
      -f \
      "$LEGACY_OPENROUTER_WRAPPER"
  fi

  install \
    -d \
    -m 0700 \
    "$STATE_DIR" \
    "${DEV_HOME}/.codex" \
    "${DEV_HOME}/.local/bin"

  {
    printf '# Managed by devbox openrouter setup\n'
    printf 'export OPENROUTER_API_KEY=%q\n' "$api_key"
  } >"$OPENROUTER_ENV"

  chmod \
    0600 \
    "$OPENROUTER_ENV"

  cat >"$OPENROUTER_PROFILE" <<EOF
# Managed by devbox openrouter setup
model = "${model}"
model_provider = "openrouter"

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
EOF

  chmod \
    0600 \
    "$OPENROUTER_PROFILE"

  cat >"$OPENROUTER_WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Managed by devbox openrouter setup

set -Eeuo pipefail

readonly openrouter_env="${HOME}/.config/devbox/openrouter.env"

[[ -r "$openrouter_env" ]] || {
  printf 'error - OpenRouter API key is not configured\n' >&2
  exit 1
}

# shellcheck source=/dev/null
source "$openrouter_env"

system_codex="$(
  PATH=/usr/local/bin:/usr/bin:/bin \
    command \
      -v \
      codex \
      || true
)"

[[ -n "$system_codex" &&
   "$system_codex" != "$0" ]] || {
  printf 'error - Native Codex CLI was not found\n' >&2
  exit 1
}

exec \
  "$system_codex" \
  --profile openrouter \
  "$@"
EOF

  chmod \
    0700 \
    "$OPENROUTER_WRAPPER"

  unset api_key

  ok "OpenRouter fallback configured"

  info "Primary: happy codex"
  info "Native:  codex"
  info "Fallback: codex-openrouter"

  openrouter_status
}

openrouter_disable() {
  require_dev

  local path

  for path in \
    "$OPENROUTER_ENV" \
    "$OPENROUTER_PROFILE" \
    "$OPENROUTER_WRAPPER" \
    "$LEGACY_OPENROUTER_WRAPPER"; do

    if is_managed_openrouter_file "$path"; then
      rm \
        -f \
        "$path"

    elif [[ -e "$path" ]]; then
      warn "Retained unmanaged file: ${path}"
    fi
  done

  ok "OpenRouter disabled and managed API key removed"
}

harden_github_state() {
  local gh_dir="${HOME}/.config/gh"

  if [[ -d "$gh_dir" ]]; then
    chmod \
      0700 \
      "$gh_dir"
  fi

  if [[ -f "${gh_dir}/hosts.yml" ]]; then
    chmod \
      0600 \
      "${gh_dir}/hosts.yml"
  fi
}

github_status() {
  require_dev

  local status=0

  if gh auth status \
    --hostname github.com \
    >/dev/null 2>&1; then

    ok "GitHub authentication"
  else
    warn "GitHub is not authenticated"
    status=1
  fi

  if [[ -n "$(git config --global user.name || true)" &&
        -n "$(git config --global user.email || true)" ]]; then

    printf 'Git name: %s\n' \
      "$(git config --global user.name)"

    printf 'Git email: %s\n' \
      "$(git config --global user.email)"
  else
    warn "Git identity is incomplete"
    status=1
  fi

  return "$status"
}

github_setup() {
  require_dev

  local account_id
  local account_login
  local default_email
  local default_name
  local git_email
  local git_name

  if ! gh auth status \
    --hostname github.com \
    >/dev/null 2>&1; then

    info "Starting GitHub device/web login"
    info "This server is headless; the GitHub URL will be printed instead of opened locally."

    # shellcheck disable=SC2209 # GH_BROWSER=echo tells gh to print the URL instead of launching a browser
    GH_BROWSER=echo \
      gh auth login \
        --hostname github.com \
        --git-protocol https \
        --web
  fi

  harden_github_state

  # Let GitHub CLI fully own the credential-helper configuration.
  #
  # Do not run a later:
  #
  #   git config credential.https://github.com.helper ...
  #
  # because gh may intentionally configure multiple helper values.
  gh auth setup-git \
    --hostname github.com

  account_login="$(
    gh api \
      user \
      --jq '.login'
  )"

  account_id="$(
    gh api \
      user \
      --jq '.id'
  )"

  default_name="$(
    gh api \
      user \
      --jq '.name // .login'
  )"

  default_email="${account_id}+${account_login}@users.noreply.github.com"

  read -r \
    -p "Git commit name [${default_name}]: " \
    git_name

  read -r \
    -p "Git commit email [${default_email}]: " \
    git_email

  git config \
    --global \
    user.name \
    "${git_name:-$default_name}"

  git config \
    --global \
    user.email \
    "${git_email:-$default_email}"

  harden_github_state

  ok "GitHub and Git identity configured"

  github_status
}

keys_status() {
  require_dev

  local public_key="${HOME}/.ssh/id_ed25519.pub"

  if [[ ! -s "$public_key" ]]; then
    warn "No DevBox identity key exists"
    return 1
  fi

  ssh-keygen \
    -l \
    -f "$public_key"

  printf '\n%s\n' \
    "$(cat "$public_key")"
}

keys_generate() {
  require_dev

  local private_key="${HOME}/.ssh/id_ed25519"

  install \
    -d \
    -m 0700 \
    "${HOME}/.ssh"

  if [[ -e "$private_key" ||
        -e "${private_key}.pub" ]]; then

    warn "Identity key already exists"

    keys_status
    return
  fi

  info "Generating outbound Ed25519 identity key"

  ssh-keygen \
    -t ed25519 \
    -a 100 \
    -C "${DEV_USER}@$(hostname)" \
    -f "$private_key"

  chmod \
    0600 \
    "$private_key"

  chmod \
    0644 \
    "${private_key}.pub"

  keys_status
}

keys_upload_github() {
  require_dev

  local public_key="${HOME}/.ssh/id_ed25519.pub"

  [[ -s "$public_key" ]] ||
    die "Generate the identity key first."

  gh auth status \
    --hostname github.com \
    >/dev/null 2>&1 \
    || die "Configure GitHub first."

  gh ssh-key add \
    "$public_key" \
    --title "$(hostname)-devbox"

  ok "Uploaded identity key to GitHub"
}

# Remote-provider hook (DEVBOX_REMOTE=happy), dispatched generically by
# remote_info() below - see devbox/README.md, "Neuen Remote-Provider
# hinzufügen".
happy_remote_info() {
  cat <<'EOF'
Happy remote development

  Happy iOS / Android / Web
              |
              v
         Happy daemon
              |
        +-----+-----+
        |           |
      Claude      Codex
        |           |
        +-----+-----+
              |
      /home/dev/workspace


Primary commands:

  happy
  happy claude
  happy codex
  hclaude
  hcodex


Native backends remain available:

  claude
  codex


Authentication:

  devbox auth status
  devbox auth login
  devbox auth logout

Happy asking you to connect/pair during `devbox auth login` is expected.


Boot behaviour:

  devbox-happy-daemon.service

Once this DevBox is paired, the Happy daemon is started at boot by that
systemd service, as user "dev". No interactive login is required after a
reboot. An unpaired DevBox leaves the service idle instead of failing.


SSH:

  devbox ssh status
  devbox ssh setup
  devbox ssh disable

DevBox SSH configuration applies only to user "dev" and does not intentionally
change root/admin SSH policy.
EOF
}

# Remote-provider hook (DEVBOX_REMOTE=kisuke), dispatched generically by
# remote_info() below - see devbox/README.md, "Neuen Remote-Provider
# hinzufügen".
kisuke_remote_info() {
  cat <<'EOF'
Kisuke Connect remote development

  Kisuke iOS / Android / Web
              |
              v
     Kisuke Connect daemon
              |
        +-----+-----+
        |           |
      Claude      Codex
        |           |
        +-----+-----+
              |
      /home/dev/workspace


Primary commands (from the Kisuke app: terminal, editor, chat):

  claude
  codex


Authentication:

  devbox auth status
  devbox auth login
  devbox auth logout

`devbox auth login` runs `kisuke connect --headless`: it prints a URL to
open on another device (no local browser is needed on this DevBox), then
waits for you to complete sign-in there.


Boot behaviour:

  systemctl --user status kisuke

Kisuke Connect manages its own boot-time service (a systemd --user unit
named "kisuke", installed by `kisuke connect` above). DevBox only enables a
lingering session for user "dev" (`loginctl enable-linger dev`) so that
service can start without an interactive login. No interactive login is
required after a reboot; a DevBox that hasn't been through `devbox auth
login` yet simply has no "kisuke" unit installed.


SSH:

  devbox ssh status
  devbox ssh setup
  devbox ssh disable

DevBox SSH configuration applies only to user "dev" and does not intentionally
change root/admin SSH policy.
EOF
}

multica_remote_info() {
  cat <<'EOF'
Multica agent workspace

  Multica web / desktop / self-hosted server
                    |
                    v
              Multica daemon
                    |
          +---------+---------+
          |                   |
        Claude               Codex
          |                   |
          +---------+---------+
                    |
          /home/dev/workspace


Multica assigns issues to the installed agent CLIs and runs them on this
DevBox. Its server is self-hosted and bound to 127.0.0.1:3000; use an SSH
tunnel or a reverse proxy to open the web interface from another machine.

Authentication:

  devbox auth status
  devbox auth login
  devbox auth logout

`devbox auth login` runs `multica setup self-host`, which configures the CLI
for this local server, authenticates, and starts the agent daemon.


Boot behaviour:

  devbox-multica-daemon.service

Once authenticated, the Multica daemon starts at boot as user "dev". An
unauthenticated DevBox leaves the service idle instead of failing.
EOF
}

remote_info() {
  local remote_provider
  remote_provider="$(configured_remote_provider)"

  if [[ "$remote_provider" != "none" ]]; then
    "${remote_provider}_remote_info"
    return
  fi

  cat <<'EOF'
No remote provider configured (DEVBOX_REMOTE=none)

This DevBox has no Happy, Kisuke or Multica remote-access layer installed. Reach it
over SSH or the host console, and use Codex/Claude directly:

  claude
  codex


Authentication:

  devbox auth status
  devbox auth login
  devbox auth logout


SSH:

  devbox ssh status
  devbox ssh setup
  devbox ssh disable

DevBox SSH configuration applies only to user "dev" and does not intentionally
change root/admin SSH policy.
EOF
}

# P2.6: read-only helpers over the dev user's project workspace. DevBox
# owns the platform, not project repositories - no branch changes,
# commits, deletions or .env creation happen here, on purpose.
workspace_list() {
  require_dev

  if [[ ! -d "$WORKSPACE_DIR" ]]; then
    warn "Workspace directory not found: ${WORKSPACE_DIR}"
    return 1
  fi

  local found=0
  local project

  while IFS= read -r -d '' project; do
    found=1
    printf '%s\n' "$(basename "$project")"
  done < <(
    find \
      "$WORKSPACE_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -print0 \
      | sort -z
  )

  [[ "$found" -eq 1 ]] ||
    info "No projects found under ${WORKSPACE_DIR}"
}

workspace_doctor() {
  require_dev

  local project="${1:-}"
  local project_dir

  [[ -n "$project" ]] ||
    die "Usage: devbox workspace doctor <project>"

  [[ "$project" != *"/"* && "$project" != *".."* ]] ||
    die "Invalid project name: ${project}"

  project_dir="${WORKSPACE_DIR}/${project}"

  if [[ ! -d "$project_dir" ]]; then
    warn "No such workspace project: ${project}"
    return 1
  fi

  ok "Project directory: ${project_dir}"

  if git \
    -C "$project_dir" \
    rev-parse \
    --is-inside-work-tree \
    >/dev/null 2>&1; then

    ok "Git repository"
  else
    warn "Not a Git repository"
  fi

  if [[ -f "${project_dir}/.env" ]]; then
    ok ".env present"
  else
    warn ".env not present"
  fi
}

# P1.2: install.sh records the optional features (elixir, postgres) a box
# was actually installed with in FEATURES_FILE. No file means the box
# predates that (or predates the feature system entirely), so every check
# runs, matching pre-P1.2 behavior.
feature_was_installed() {
  [[ -r "$FEATURES_FILE" ]] || return 0
  grep -Fqw "$1" "$FEATURES_FILE"
}

# #43: the configured remote provider ("happy", "kisuke" or "none"). No
# REMOTE_PROVIDER_FILE means the box predates this feature, when Happy was
# unconditionally installed - "happy" is the correct migrated value.
configured_remote_provider() {
  if [[ -r "$REMOTE_PROVIDER_FILE" ]]; then
    printf '%s' "$(<"$REMOTE_PROVIDER_FILE")"
  else
    printf 'happy'
  fi
}

# P2.2: "How is this specific box configured?" A composite view built from
# the Root-State files and the existing per-domain status commands
# (ssh_status, auth/github/openrouter status) rather than reimplementing
# their checks here.
status() {
  local devbox_version="unknown"
  local profile="unknown"
  local feature

  if [[ -r "$ROOT_VERSION_FILE" ]]; then
    devbox_version="$(<"$ROOT_VERSION_FILE")"
  fi

  if [[ -r "$INSTALL_STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    profile="$(jq -r '.profile // "unknown"' "$INSTALL_STATE_FILE" 2>/dev/null)"
    [[ -n "$profile" ]] || profile="unknown"
  fi

  printf 'DevBox version:      %s\n' "$devbox_version"
  printf 'Commit:              %s\n' "$(installed_commit)"
  printf 'Profile:             %s\n' "$profile"
  printf 'Remote provider:     %s\n\n' "$(configured_remote_provider)"

  printf 'Features:\n'

  for feature in elixir postgres redis; do
    if feature_was_installed "$feature"; then
      printf '  %-18s enabled\n' "$feature"
    else
      printf '  %-18s disabled\n' "$feature"
    fi
  done

  printf '\n'
  ssh_status
  printf '\n'

  # auth/github/openrouter status all require_dev; re-invoke this same
  # manager as dev instead of duplicating their checks in this function.
  run_as_dev "$0" auth status || true
  printf '\n'
  run_as_dev "$0" github status || true
  printf '\n'
  run_as_dev "$0" openrouter status || true
}

doctor() {
  local json_mode=0
  [[ "${1:-}" == "json" ]] && json_mode=1

  local command
  local status=0
  local happy_version=""
  local kisuke_version=""

  # Captured alongside the checks below (unchanged) so --json can report a
  # structured summary without re-running or duplicating any of them.
  local os_id="unknown"
  local os_version="unknown"
  local runtime_node=""
  local runtime_erlang=""
  local runtime_elixir=""
  local service_postgres=""
  local service_redis=""
  local service_happy_daemon="unknown"
  local service_kisuke_daemon="unknown"
  local auth_codex=false
  local auth_claude=false
  local auth_happy=false
  local auth_kisuke=false
  local auth_github=false
  local security_ssh_policy="unmanaged"
  local security_happy_dir_permissions=false
  local security_kisuke_dir_permissions=false
  local security_secret_permissions=false

  # Duplicated via an fd number (dup2), not reopened by path: opening
  # "/dev/stdout" (-> /proc/self/fd/1) can fail with EACCES depending on
  # how the parent process set up the pipe backing fd 1, even though the
  # process already holds fd 1 open for writing.
  local checks_fd=1
  if [[ "$json_mode" == 1 ]]; then
    exec {checks_fd}>/dev/null
  fi

  # #43: doctor only checks the configured remote provider. A box with
  # DEVBOX_REMOTE=none never installed Happy or Kisuke, so none of their
  # checks apply there - "not configured" rather than a failure.
  local remote_provider
  remote_provider="$(configured_remote_provider)"

  if [[ "$remote_provider" != "happy" ]]; then
    service_happy_daemon="not configured"
    security_happy_dir_permissions=true
  fi

  if [[ "$remote_provider" != "kisuke" ]]; then
    service_kisuke_daemon="not configured"
    security_kisuke_dir_permissions=true
  fi

  # Kisuke manages its own credential file permissions (its on-disk format
  # isn't documented the way Happy's is - see harden_kisuke_state()), so
  # this field only ever reflects Happy's access-key check; it defaults
  # true for both "kisuke" and "none".
  if [[ "$remote_provider" != "happy" ]]; then
    security_secret_permissions=true
  fi

  {

  if [[ -r /etc/os-release ]]; then
    os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-unknown}")"
    os_version="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-unknown}")"
  fi

  if [[ -r "$ROOT_VERSION_FILE" ]]; then
    if [[ "$(<"$ROOT_VERSION_FILE")" == "$DEVBOX_VERSION" ]]; then
      ok "DevBox root state (${DEVBOX_VERSION})"
    else
      warn "Root state version ($(<"$ROOT_VERSION_FILE")) does not match the running manager (${DEVBOX_VERSION})"
      status=1
    fi
  else
    warn "No DevBox root state found at ${ROOT_STATE_DIR} (install predates P1.4, or state was removed)"
  fi

  local commands=(
    claude
    codex
    fd
    gh
    git
    jq
    node
    npm
    python3
    rg
  )

  if [[ "$remote_provider" == "happy" ]]; then
    commands+=(happy)
  elif [[ "$remote_provider" == "kisuke" ]]; then
    commands+=(kisuke)
  elif [[ "$remote_provider" == "multica" ]]; then
    commands+=(multica)
  fi

  if feature_was_installed elixir; then
    commands+=(elixir erl mix)
    runtime_erlang="$ERLANG_VERSION"
    runtime_elixir="$ELIXIR_VERSION"
  fi

  if feature_was_installed postgres; then
    commands+=(psql)
  fi

  if feature_was_installed redis; then
    commands+=(redis-cli)
  fi

  for command in "${commands[@]}"; do
    if run_as_dev \
      bash \
      -lc \
      "command -v ${command} >/dev/null 2>&1"; then

      ok "$command"
    else
      warn "$command is missing"
      status=1
    fi
  done

  runtime_node="$(node --version 2>/dev/null | sed 's/^v//')"

  if [[ "$(node --version)" == "v${NODE_MAJOR}."* ]]; then
    ok "Node.js ${NODE_MAJOR}"
  else
    warn "Unexpected Node.js version: $(node --version 2>/dev/null || true)"
    status=1
  fi

  if feature_was_installed postgres; then
    if systemctl is-active \
      --quiet \
      postgresql.service; then

      ok "PostgreSQL service"
      service_postgres="running"
    else
      warn "PostgreSQL service is not active"
      status=1
      service_postgres="not running"
    fi
  fi

  if feature_was_installed redis; then
    if systemctl is-active \
      --quiet \
      redis-server.service; then

      ok "Redis service"
      service_redis="running"
    else
      warn "Redis service is not active"
      status=1
      service_redis="not running"
    fi
  fi

  if feature_was_installed elixir; then
    if run_as_dev erl \
      -noshell \
      -eval 'halt(0).'; then

      ok "Erlang runtime"
    else
      warn "Erlang runtime failed"
      status=1
    fi
  fi

  run_as_dev codex \
    --version \
    || status=1

  run_as_dev claude \
    --version \
    || status=1

  # Do not invoke `happy --version`: current Happy versions may continue into
  # normal first-use startup. Validate the globally installed npm package.
  if [[ "$remote_provider" == "happy" ]]; then
    if run_as_dev npm list \
      --global \
      --depth=0 \
      happy \
      >/dev/null 2>&1; then

      happy_version="$(
        run_as_dev npm list \
          --global \
          --depth=0 \
          happy \
          2>/dev/null \
        | grep -E 'happy@' \
        | head -n1 \
        || true
      )"

      ok "${happy_version:-Happy npm package}"
    else
      warn "Happy npm package is missing"
      status=1
    fi
  fi

  # Do not invoke `kisuke --version` for the same reason as `happy` above -
  # validate the globally installed npm package instead.
  if [[ "$remote_provider" == "kisuke" ]]; then
    if run_as_dev npm list \
      --global \
      --depth=0 \
      @kisuke/cli \
      >/dev/null 2>&1; then

      kisuke_version="$(
        run_as_dev npm list \
          --global \
          --depth=0 \
          @kisuke/cli \
          2>/dev/null \
        | grep -E '@kisuke/cli@' \
        | head -n1 \
        || true
      )"

      ok "${kisuke_version:-Kisuke npm package}"
    else
      warn "Kisuke npm package is missing"
      status=1
    fi
  fi

  if feature_was_installed elixir; then
    run_as_dev elixir \
      --version \
      || status=1

    run_as_dev mix phx.new \
      --version \
      || status=1
  fi

  # Authentication status is informational for a fresh install.

  if run_as_dev \
    bash \
    -lc \
    'codex login status >/dev/null 2>&1'; then

    ok "Codex CLI is authenticated"
    auth_codex=true
  else
    warn "Codex CLI is not authenticated (run: devbox auth login)"
  fi

  if run_as_dev \
    bash \
    -lc \
    'claude auth status >/dev/null 2>&1'; then

    ok "Claude CLI is authenticated"
    auth_claude=true
  else
    warn "Claude CLI is not authenticated (run: devbox auth login)"
  fi

  if run_as_dev \
    bash \
    -lc \
    'gh auth status >/dev/null 2>&1'; then

    ok "GitHub CLI is authenticated"
    auth_github=true
  else
    warn "GitHub CLI is not authenticated (run: devbox github setup)"
  fi

  if [[ "$remote_provider" == "happy" ]]; then
    # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
    if run_as_dev \
      bash \
      -lc \
      '
        [[ -s "$HOME/.happy/access.key" ]] &&
        [[ -s "$HOME/.happy/settings.json" ]] &&
        jq -e "
          (.machineId? | type == \"string\")
          and
          (.machineId | length > 0)
        " "$HOME/.happy/settings.json" >/dev/null 2>&1
      '; then

      ok "Happy is paired"
      auth_happy=true
    else
      warn "Happy is not paired (run: devbox auth login)"
    fi

    # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
    if run_as_dev \
      bash \
      -lc \
      '
        state="$HOME/.happy/daemon.state.json"

        [[ -s "$state" ]] ||
          exit 1

        pid="$(
          jq -r ".pid // empty" "$state" 2>/dev/null ||
          true
        )"

        [[ "$pid" =~ ^[0-9]+$ ]] ||
          exit 1

        kill -0 "$pid" 2>/dev/null
      '; then

      ok "Happy daemon"
      service_happy_daemon="running"
    else
      warn "Happy daemon is not running"
      service_happy_daemon="not running"
    fi

    # Remote access has to survive a reboot on its own (issue #19): without
    # the boot service, Happy only comes back once somebody opens an
    # interactive dev shell.
    if happy_daemon_service_is_installed; then
      if happy_daemon_service_is_enabled; then
        ok "Happy daemon service (${HAPPY_SERVICE})"
      else
        warn "${HAPPY_SERVICE} is installed but not enabled"
        status=1
      fi

      if systemctl is-failed \
        --quiet \
        "$HAPPY_SERVICE" \
        2>/dev/null; then

        warn "${HAPPY_SERVICE} is in a failed state (systemctl status ${HAPPY_SERVICE})"
        status=1
      fi
    else
      warn "${HAPPY_SERVICE} is not installed; Happy only starts from an interactive dev shell"
      status=1
    fi

    # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
    if run_as_dev \
      bash \
      -lc \
      '
        [[ ! -e "$HOME/.happy" ]] ||
        [[ "$(stat -c "%a" "$HOME/.happy")" == "700" ]]
      '; then

      ok "Happy data directory permissions"
      security_happy_dir_permissions=true
    else
      # shellcheck disable=SC2088 # literal display text, not a path expansion
      warn "~/.happy should have mode 0700"
      status=1
    fi

    # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
    if run_as_dev \
      bash \
      -lc \
      '
        [[ ! -e "$HOME/.happy/access.key" ]] ||
        [[ "$(stat -c "%a" "$HOME/.happy/access.key")" == "600" ]]
      '; then

      ok "Happy access key permissions"
      security_secret_permissions=true
    else
      # shellcheck disable=SC2088 # literal display text, not a path expansion
      warn "~/.happy/access.key should have mode 0600"
      status=1
    fi

  elif [[ "$remote_provider" == "kisuke" ]]; then
    if kisuke_is_authenticated; then
      ok "Kisuke is authenticated"
      auth_kisuke=true
    else
      warn "Kisuke is not authenticated (run: devbox auth login)"
    fi

    if kisuke_daemon_is_running; then
      ok "Kisuke daemon"
      service_kisuke_daemon="running"
    else
      warn "Kisuke daemon is not running"
      service_kisuke_daemon="not running"
    fi

    # Unlike Happy's devbox-happy-daemon.service (installed AND enabled
    # atomically, in one step, unconditionally by install.sh), Kisuke's own
    # "kisuke" systemd --user unit is written and enabled across several
    # steps of `kisuke connect`'s own guided setup - a box that hasn't
    # completed that yet (or hit a transient failure partway through, e.g.
    # #69/#70's D-Bus races) can legitimately have the unit installed but
    # not enabled, or not installed at all. Both are informational here,
    # like the authentication/daemon-running checks above: none of this is
    # something DevBox itself owns or can fix by re-running the installer,
    # and treating it as fatal would abort `install.sh`/`devbox update`'s
    # own doctor validation step over a state `devbox auth login` is
    # expected to resolve.
    if kisuke_daemon_service_is_installed; then
      if kisuke_daemon_service_is_enabled; then
        ok "Kisuke daemon service (${KISUKE_SERVICE})"
      else
        warn "${KISUKE_SERVICE} service is installed but not enabled (run: devbox auth login)"
      fi
    else
      warn "${KISUKE_SERVICE} service is not installed yet; run: devbox auth login"
    fi

    # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
    if run_as_dev \
      bash \
      -lc \
      '
        [[ ! -e "$HOME/.kisuke" ]] ||
        [[ "$(stat -c "%a" "$HOME/.kisuke")" == "700" ]]
      '; then

      ok "Kisuke data directory permissions"
      security_kisuke_dir_permissions=true
    else
      # shellcheck disable=SC2088 # literal display text, not a path expansion
      warn "~/.kisuke should have mode 0700"
      status=1
    fi
  elif [[ "$remote_provider" == "multica" ]]; then
    if multica_is_authenticated; then
      ok "Multica is authenticated"
    else
      warn "Multica is not authenticated (run: devbox auth login)"
    fi

    if multica_self_host_is_running; then
      ok "Multica self-hosted server"
    else
      warn "Multica self-hosted server is not running"
      status=1
    fi

    if multica_daemon_is_running; then
      ok "Multica daemon"
    else
      warn "Multica daemon is not running"
    fi

    if multica_daemon_service_is_installed && multica_daemon_service_is_enabled; then
      ok "Multica daemon service (${MULTICA_SERVICE})"
    else
      warn "Multica daemon service is not enabled; run: devbox update as root"
      status=1
    fi
  fi

  # shellcheck disable=SC2016 # single-quoted on purpose: expands inside the nested `bash -lc` shell, not here
  if run_as_dev \
    bash \
    -lc \
    '
      [[ "${LANG:-}" == *UTF-8* ||
         "${LANG:-}" == *utf8* ||
         "${LANG:-}" == *UTF8* ]]
    '; then

    ok "UTF-8 locale"
  else
    warn "Developer locale is not UTF-8"
    status=1
  fi

  if [[ -f "$SSH_CONFIG" ]] &&
    grep \
      -Eq \
      '^(PermitRootLogin no|AllowUsers dev)$' \
      "$SSH_CONFIG"; then

    warn "Legacy global DevBox SSH restriction detected"
    status=1
  else
    ok "No DevBox global root SSH restriction"
  fi

  ssh_status

  # ssh_status() above prints its own classification but has no return
  # value to reuse; this mirrors its policy detection (the only duplication
  # in this function) purely to expose it as a machine-readable field.
  if [[ -f "$SSH_CONFIG" ]]; then
    if grep \
      -Eq \
      '^DenyUsers[[:space:]]+dev([[:space:]]|$)' \
      "$SSH_CONFIG"; then

      security_ssh_policy="disabled"

    elif grep \
      -Eq \
      '^Match[[:space:]]+User[[:space:]]+dev([[:space:]]|$)' \
      "$SSH_CONFIG"; then

      security_ssh_policy="public-key-only"
    fi
  fi

  } >&"$checks_fd"

  if [[ "$json_mode" == 1 ]]; then
    jq \
      -n \
      --argjson healthy "$([[ "$status" -eq 0 ]] && echo true || echo false)" \
      --arg devbox_version "$DEVBOX_VERSION" \
      --arg remote_provider "$remote_provider" \
      --arg os_id "$os_id" \
      --arg os_version "$os_version" \
      --arg node "$runtime_node" \
      --arg erlang "$runtime_erlang" \
      --arg elixir "$runtime_elixir" \
      --arg postgres "$service_postgres" \
      --arg redis "$service_redis" \
      --arg happy_daemon "$service_happy_daemon" \
      --arg kisuke_daemon "$service_kisuke_daemon" \
      --argjson auth_codex "$auth_codex" \
      --argjson auth_claude "$auth_claude" \
      --argjson auth_happy "$auth_happy" \
      --argjson auth_kisuke "$auth_kisuke" \
      --argjson auth_github "$auth_github" \
      --arg ssh_policy "$security_ssh_policy" \
      --argjson happy_dir_permissions "$security_happy_dir_permissions" \
      --argjson kisuke_dir_permissions "$security_kisuke_dir_permissions" \
      --argjson secret_permissions "$security_secret_permissions" \
      '{
        healthy: $healthy,
        devbox_version: $devbox_version,
        remote_provider: $remote_provider,
        os: { id: $os_id, version: $os_version },
        runtime: {
          node: (if $node == "" then null else $node end),
          erlang: (if $erlang == "" then null else $erlang end),
          elixir: (if $elixir == "" then null else $elixir end)
        },
        services: {
          postgres: (if $postgres == "" then null else $postgres end),
          redis: (if $redis == "" then null else $redis end),
          happy_daemon: $happy_daemon,
          kisuke_daemon: $kisuke_daemon
        },
        authentication: {
          codex: $auth_codex,
          claude: $auth_claude,
          happy: $auth_happy,
          kisuke: $auth_kisuke,
          github: $auth_github
        },
        security: {
          ssh_dev_policy: $ssh_policy,
          happy_dir_permissions: $happy_dir_permissions,
          kisuke_dir_permissions: $kisuke_dir_permissions,
          secret_permissions: $secret_permissions
        }
      }'
  fi

  return "$status"
}

# Resolves the latest published release's tag via the GitHub Releases API.
# Prints nothing (not an error) if there are no releases yet, or the API
# call fails for any other reason - callers treat both the same way: "no
# release-based update is available right now."
latest_release_tag() {
  local github_repo="$1"
  local response

  response="$(
    curl \
      -fsSL \
      --connect-timeout 15 \
      "https://api.github.com/repos/${github_repo}/releases/latest" \
      2>/dev/null \
      || true
  )"

  [[ -n "$response" ]] || return 0

  printf '%s' "$response" \
    | jq -r '.tag_name // empty' 2>/dev/null \
    || true
}

# P2.1: resolves a branch/tag to the commit it currently names, so
# `update --check` on a branch can report whether the installed commit is
# actually stale instead of the old blanket "not version-compared"
# disclaimer. Mirrors install.sh's resolve_devbox_ref_to_commit(), but
# uses jq here since - unlike install.sh's early bootstrap - it's always
# available by the time the manager runs. Prints nothing on any failure
# (network, rate limit, unknown ref); callers treat that as "unknown".
resolve_ref_to_commit() {
  local github_repo="$1"
  local ref="$2"
  local response

  response="$(
    curl \
      -fsSL \
      --connect-timeout 15 \
      --header "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${github_repo}/commits/${ref}" \
      2>/dev/null \
      || true
  )"

  [[ -n "$response" ]] || return 0

  printf '%s' "$response" \
    | jq -r '.sha // empty' 2>/dev/null \
    || true
}

# Tolerates a leading "v" on either side (release tags are "v1.2.3", the
# embedded DEVBOX_VERSION is "1.2.3").
version_is_newer() {
  local candidate="${1#v}"
  local current="${2#v}"

  [[ "$candidate" != "$current" ]] &&
    [[ "$(
      printf '%s\n%s\n' "$candidate" "$current" \
        | sort -V \
        | tail -n1
    )" == "$candidate" ]]
}

# Migrates the P1.3-era single env-file (user-state) into the P1.4
# root-state files, once, the first time this runs after an upgrade.
#
# P0.2: this file lives under the dev-writable user-state directory but is
# read here as root (via update_devbox()/rollback_devbox()). It must never
# be `source`d or `eval`d - a KEY=VALUE line is data, parsed by hand, and
# only the three known keys are recognized; anything else (including a
# line crafted to look like shell code) is silently ignored.
migrate_legacy_previous_update_state() {
  [[ -f "$LEGACY_PREVIOUS_UPDATE_FILE" ]] || return 0
  [[ -f "$PREVIOUS_REF_FILE" ]] && return 0

  local previous_mode=""
  local previous_target=""
  local previous_version=""
  local key value

  while IFS='=' read -r key value; do
    case "$key" in
      PREVIOUS_MODE)
        [[ "$value" =~ ^(release|branch)$ ]] &&
          previous_mode="$value"
        ;;

      PREVIOUS_TARGET)
        [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] &&
          previous_target="$value"
        ;;

      PREVIOUS_VERSION)
        [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
          previous_version="$value"
        ;;
    esac
  done <"$LEGACY_PREVIOUS_UPDATE_FILE"

  if [[ -n "$previous_mode" && -n "$previous_target" ]]; then
    printf '%s:%s\n' "$previous_mode" "$previous_target" >"$PREVIOUS_REF_FILE"
  fi

  if [[ -n "$previous_version" ]]; then
    printf '%s\n' "$previous_version" >"$PREVIOUS_VERSION_FILE"
  fi

  rm -f "$LEGACY_PREVIOUS_UPDATE_FILE"
}

record_previous_update_state() {
  local mode="$1"
  local ref="$2"

  install \
    -d \
    -m 0755 \
    "$ROOT_STATE_DIR"

  migrate_legacy_previous_update_state

  printf '%s:%s\n' "$mode" "$ref" >"$PREVIOUS_REF_FILE"
  printf '%s\n' "$DEVBOX_VERSION" >"$PREVIOUS_VERSION_FILE"

  chmod \
    0644 \
    "$PREVIOUS_REF_FILE" \
    "$PREVIOUS_VERSION_FILE"
}

update_devbox() {
  info "Current DevBox version: v${DEVBOX_VERSION}"

  require_root

  local repo_url="${DEVBOX_REPO_URL:-$DEFAULT_REPO_URL}"
  local github_repo="${DEVBOX_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}"
  local mode="release"
  local target=""
  local check_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        check_only=1
        shift
        ;;

      --to)
        [[ -n "${2:-}" ]] || die "Usage: devbox update --to <tag>"
        mode="release"
        target="$2"
        shift 2
        ;;

      --branch)
        [[ -n "${2:-}" ]] || die "Usage: devbox update --branch <name>"
        mode="branch"
        target="$2"
        shift 2
        ;;

      -*)
        die "Unknown update option: $1"
        ;;

      *)
        # Backward-compatible shorthand: `devbox update <branch>`.
        mode="branch"
        target="$1"
        shift
        ;;
    esac
  done

  if [[ "$mode" == "release" && -z "$target" ]]; then
    info "Looking up the latest published release"
    target="$(latest_release_tag "$github_repo")"

    if [[ -z "$target" ]]; then
      if [[ "$check_only" -eq 1 ]]; then
        ok "No published releases yet"
        return 0
      fi

      die "No published releases found. Use 'devbox update --branch <name>' to update from a branch instead."
    fi
  fi

  if [[ "$check_only" -eq 1 ]]; then
    if [[ "$mode" == "release" ]]; then
      if version_is_newer "$target" "$DEVBOX_VERSION"; then
        ok "Update available: ${DEVBOX_VERSION} -> ${target}"
      else
        ok "Already up to date (${DEVBOX_VERSION})"
      fi
    else
      local remote_commit
      remote_commit="$(resolve_ref_to_commit "$github_repo" "$target")"

      if [[ -z "$remote_commit" ]]; then
        ok "Would update from branch '${target}' (could not resolve its current commit to compare)"
      elif [[ "$remote_commit" == "$(installed_commit)" ]]; then
        ok "Already up to date (branch '${target}' at ${remote_commit})"
      else
        ok "Update available on branch '${target}': $(installed_commit) -> ${remote_commit}"
      fi
    fi

    return 0
  fi

  local ref="$target"
  local installer_url="${repo_url%/}/${ref}/devbox/install.sh"
  local installer

  installer="$(mktemp)"

  info "Downloading installer from ${mode} '${ref}'"

  if ! curl \
    -fsSL \
    --connect-timeout 15 \
    --retry 5 \
    --retry-connrefused \
    --retry-delay 3 \
    -o "$installer" \
    "$installer_url"; then

    rm \
      -f \
      "$installer"

    die "Failed to download installer from ${installer_url}"
  fi

  chmod \
    0755 \
    "$installer"

  if ! bash \
    -n \
    "$installer"; then

    rm \
      -f \
      "$installer"

    die "Downloaded installer failed bash syntax validation"
  fi

  # P1.1: record what was active BEFORE this update, not the new target -
  # otherwise `devbox rollback` re-installs the same ref it's already on.
  # No ACTIVE_REF_FILE means an install from before this file existed;
  # skip recording rather than write a previous-ref that isn't real.
  local active_mode="" active_target=""

  if [[ -r "$ACTIVE_REF_FILE" ]]; then
    local active_ref
    active_ref="$(<"$ACTIVE_REF_FILE")"
    active_mode="${active_ref%%:*}"
    active_target="${active_ref#*:}"

    [[ -n "$active_mode" && -n "$active_target" && "$active_mode" != "$active_target" ]] ||
      active_mode="" active_target=""
  fi

  if [[ -n "$active_mode" && -n "$active_target" ]]; then
    record_previous_update_state "$active_mode" "$active_target"
  fi

  info "Re-running installer"

  # #43: respects this box's existing remote-provider selection instead of
  # letting install.sh silently fall back to its own "happy" default. A box
  # from before this feature has no REMOTE_PROVIDER_FILE yet - defaulting
  # to "happy" here is exactly the required migration behavior for those.
  local remote_provider="happy"
  [[ -r "$REMOTE_PROVIDER_FILE" ]] && remote_provider="$(<"$REMOTE_PROVIDER_FILE")"

  DEVBOX_REPO_URL="$repo_url" \
    DEVBOX_REF="$ref" \
    DEVBOX_REMOTE="$remote_provider" \
    bash "$installer"

  rm \
    -f \
    "$installer"

  install \
    -d \
    -m 0755 \
    "$ROOT_STATE_DIR"

  printf '%s:%s\n' "$mode" "$ref" >"$ACTIVE_REF_FILE"

  chmod \
    0644 \
    "$ACTIVE_REF_FILE"

  ok "Updated from ${mode} '${ref}'"

  doctor
}

rollback_devbox() {
  require_root

  migrate_legacy_previous_update_state

  [[ -r "$PREVIOUS_REF_FILE" ]] ||
    die "No previous update recorded; nothing to roll back to."

  local previous_ref
  local previous_mode
  local previous_target
  local previous_version=""

  previous_ref="$(<"$PREVIOUS_REF_FILE")"
  previous_mode="${previous_ref%%:*}"
  previous_target="${previous_ref#*:}"

  [[ -n "$previous_mode" && -n "$previous_target" && "$previous_mode" != "$previous_target" ]] ||
    die "Previous update state is incomplete; cannot roll back."

  [[ -r "$PREVIOUS_VERSION_FILE" ]] && previous_version="$(<"$PREVIOUS_VERSION_FILE")"

  info "Rolling back to ${previous_mode} '${previous_target}' (${previous_version:-unknown version}, currently on ${DEVBOX_VERSION})"

  if [[ "$previous_mode" == "branch" ]]; then
    update_devbox --branch "$previous_target"
  else
    update_devbox --to "$previous_target"
  fi
}

onboard() {
  require_dev

  [[ -t 0 && -t 1 ]] ||
    return 0

  install \
    -d \
    -m 0700 \
    "$STATE_DIR"

  local remote_provider
  remote_provider="$(configured_remote_provider)"

  local remote_step="Authenticate Codex and Claude"
  case "$remote_provider" in
    happy) remote_step="Authenticate Codex and Claude and pair Happy" ;;
    kisuke) remote_step="Authenticate Codex, Claude and Kisuke Connect" ;;
    multica) remote_step="Authenticate Codex, Claude and Multica" ;;
  esac

  cat <<EOF

DevBox onboarding

1. Optional SSH access for the dev account
2. ${remote_step}
3. Optional OpenRouter Codex fallback
4. GitHub authentication and Git identity
5. Optional outbound Ed25519 identity key
6. Environment diagnostics

EOF

  case "$remote_provider" in
    happy)
      cat <<'EOF'
Primary agent commands after onboarding:

  happy
  happy claude
  happy codex


Native backends remain available:

  claude
  codex

EOF
      ;;
    kisuke)
      cat <<'EOF'
Agent commands after onboarding:

  claude
  codex

Reach this box from the Kisuke app (terminal, editor, chat) once
'devbox auth login' has authenticated Kisuke Connect.

EOF
      ;;
    multica)
      cat <<'EOF'
Agent commands after onboarding:

  claude
  codex

Use Multica to create agents and assign them work on this DevBox once
'devbox auth login' has authenticated Multica.

EOF
      ;;
    *)
      cat <<'EOF'
Agent commands after onboarding:

  claude
  codex

EOF
      ;;
  esac

  cat <<'EOF'
Configuring dev SSH does not disable or alter administrative/root SSH access.

EOF

  if prompt_yes_no \
    "Configure SSH access for the dev account now?"; then

    sudo \
      -n \
      /usr/local/bin/devbox \
      ssh setup
  fi

  local login_prompt="Sign in to Codex and Claude now?"
  case "$remote_provider" in
    happy) login_prompt="Sign in to Codex and Claude and pair Happy now?" ;;
    kisuke) login_prompt="Sign in to Codex, Claude and Kisuke Connect now?" ;;
    multica) login_prompt="Sign in to Codex, Claude and Multica now?" ;;
  esac

  if prompt_yes_no \
    "$login_prompt"; then

    agents_auth_login
  fi

  if prompt_yes_no \
    "Configure OpenRouter as a Codex fallback?" \
    "no"; then

    openrouter_setup
  fi

  if prompt_yes_no \
    "Configure GitHub now?"; then

    github_setup
  fi

  if prompt_yes_no \
    "Generate a DevBox identity key?" \
    "no"; then

    keys_generate

    if gh auth status \
      --hostname github.com \
      >/dev/null 2>&1 \
      && prompt_yes_no \
        "Upload this public key to GitHub?" \
        "no"; then

      keys_upload_github
    fi
  fi

  remote_info

  doctor \
    || warn "Doctor found required or optional items that need attention"

  : >"$ONBOARDING_MARKER"

  chmod \
    0600 \
    "$ONBOARDING_MARKER"

  ok "Onboarding completed"
}

main() {
  local command="${1:-help}"
  local subcommand="${2:-}"

  case "$command:$subcommand" in
    onboard:)
      onboard
      ;;

    ssh:status)
      ssh_status
      ;;

    ssh:setup)
      ssh_setup
      ;;

    ssh:disable)
      ssh_disable
      ;;

    packages:list)
      packages_list
      ;;

    packages:install)
      packages_install "${@:3}"
      ;;

    version:)
      show_version
      ;;

    version:--json)
      show_version_json
      ;;

    auth:status)
      agents_auth_status
      ;;

    auth:login)
      agents_auth_login
      ;;

    auth:logout)
      agents_auth_logout
      ;;

    openrouter:status)
      openrouter_status
      ;;

    openrouter:setup)
      openrouter_setup
      ;;

    openrouter:disable)
      openrouter_disable
      ;;

    github:status)
      github_status
      ;;

    github:setup)
      github_setup
      ;;

    keys:status)
      keys_status
      ;;

    keys:generate)
      keys_generate
      ;;

    keys:upload-github)
      keys_upload_github
      ;;

    remote-info:)
      remote_info
      ;;

    status:)
      status
      ;;

    workspace:list)
      workspace_list
      ;;

    workspace:doctor)
      workspace_doctor "${@:3}"
      ;;

    doctor:)
      doctor
      ;;

    doctor:--json)
      doctor json
      ;;

    update:*)
      update_devbox "${@:2}"
      ;;

    rollback:)
      rollback_devbox
      ;;

    help: | -h: | --help:)
      usage
      ;;

    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
