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

readonly OPENROUTER_ENV="${STATE_DIR}/openrouter.env"
readonly OPENROUTER_PROFILE="${DEV_HOME}/.codex/openrouter.config.toml"
readonly OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex-openrouter"
readonly LEGACY_OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex"

readonly NODE_MAJOR="24"

# Mirrors the version manifest embedded in install.sh / devbox/versions.env.
readonly DEVBOX_VERSION="1.1.1"
readonly ERLANG_VERSION="29.0.5"
readonly ELIXIR_VERSION="1.20.3"
readonly PHOENIX_VERSION="1.8.9"
readonly CODEX_VERSION="0.147.0"
readonly CLAUDE_VERSION="2.1.233"
readonly HAPPY_VERSION="1.2.0"

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
      Show Happy, Codex and Claude authentication status.

  auth login
      Authenticate Codex and Claude, pair Happy and start Happy daemon.

  auth logout
      Sign out of Happy, Codex and Claude.

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
      Explain Happy remote access.

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
    '{
      devbox: $devbox,
      commit: $commit,
      node: $node,
      erlang: $erlang,
      elixir: $elixir,
      phoenix: $phoenix,
      codex_cli: $codex_cli,
      claude_code: $claude_code,
      happy: $happy
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

agents_auth_status() {
  require_dev

  local status=0

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

agents_auth_login() {
  require_dev

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

  agents_auth_status
}

agents_auth_logout() {
  require_dev

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

remote_info() {
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
  printf 'Profile:             %s\n\n' "$profile"

  printf 'Features:\n'

  for feature in elixir postgres; do
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

  # Captured alongside the checks below (unchanged) so --json can report a
  # structured summary without re-running or duplicating any of them.
  local os_id="unknown"
  local os_version="unknown"
  local runtime_node=""
  local runtime_erlang=""
  local runtime_elixir=""
  local service_postgres=""
  local service_happy_daemon="unknown"
  local auth_codex=false
  local auth_claude=false
  local auth_happy=false
  local auth_github=false
  local security_ssh_policy="unmanaged"
  local security_happy_dir_permissions=false
  local security_secret_permissions=false

  local checks_target=/dev/stdout
  [[ "$json_mode" == 1 ]] && checks_target=/dev/null

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
    happy
    fd
    gh
    git
    jq
    node
    npm
    python3
    rg
  )

  if feature_was_installed elixir; then
    commands+=(elixir erl mix)
    runtime_erlang="$ERLANG_VERSION"
    runtime_elixir="$ELIXIR_VERSION"
  fi

  if feature_was_installed postgres; then
    commands+=(psql)
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

  } >"$checks_target"

  if [[ "$json_mode" == 1 ]]; then
    jq \
      -n \
      --argjson healthy "$([[ "$status" -eq 0 ]] && echo true || echo false)" \
      --arg devbox_version "$DEVBOX_VERSION" \
      --arg os_id "$os_id" \
      --arg os_version "$os_version" \
      --arg node "$runtime_node" \
      --arg erlang "$runtime_erlang" \
      --arg elixir "$runtime_elixir" \
      --arg postgres "$service_postgres" \
      --arg happy_daemon "$service_happy_daemon" \
      --argjson auth_codex "$auth_codex" \
      --argjson auth_claude "$auth_claude" \
      --argjson auth_happy "$auth_happy" \
      --argjson auth_github "$auth_github" \
      --arg ssh_policy "$security_ssh_policy" \
      --argjson happy_dir_permissions "$security_happy_dir_permissions" \
      --argjson secret_permissions "$security_secret_permissions" \
      '{
        healthy: $healthy,
        devbox_version: $devbox_version,
        os: { id: $os_id, version: $os_version },
        runtime: {
          node: (if $node == "" then null else $node end),
          erlang: (if $erlang == "" then null else $erlang end),
          elixir: (if $elixir == "" then null else $elixir end)
        },
        services: {
          postgres: (if $postgres == "" then null else $postgres end),
          happy_daemon: $happy_daemon
        },
        authentication: {
          codex: $auth_codex,
          claude: $auth_claude,
          happy: $auth_happy,
          github: $auth_github
        },
        security: {
          ssh_dev_policy: $ssh_policy,
          happy_dir_permissions: $happy_dir_permissions,
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

  DEVBOX_REPO_URL="$repo_url" \
    DEVBOX_REF="$ref" \
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

  cat <<'EOF'

DevBox onboarding

1. Optional SSH access for the dev account
2. Authenticate Codex and Claude and pair Happy
3. Optional OpenRouter Codex fallback
4. GitHub authentication and Git identity
5. Optional outbound Ed25519 identity key
6. Environment diagnostics


Primary agent commands after onboarding:

  happy
  happy claude
  happy codex


Native backends remain available:

  claude
  codex


Configuring dev SSH does not disable or alter administrative/root SSH access.

EOF

  if prompt_yes_no \
    "Configure SSH access for the dev account now?"; then

    sudo \
      -n \
      /usr/local/bin/devbox \
      ssh setup
  fi

  if prompt_yes_no \
    "Sign in to Codex and Claude and pair Happy now?"; then

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
