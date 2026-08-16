#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly DEV_USER="dev"
readonly DEV_HOME="/home/${DEV_USER}"

readonly STATE_DIR="${DEV_HOME}/.config/devbox"
readonly ONBOARDING_MARKER="${STATE_DIR}/onboarding-complete"
readonly FEATURES_FILE="${STATE_DIR}/features"

readonly SSH_CONFIG="/etc/ssh/sshd_config.d/00-devbox.conf"
readonly SSH_KEY_FILE="${DEV_HOME}/.ssh/authorized_keys.devbox"
readonly SSH_STANDARD_KEY_FILE="${DEV_HOME}/.ssh/authorized_keys"
readonly SSH_DISABLED_MARKER="${STATE_DIR}/ssh-disabled"

readonly HAPPY_HOME="${DEV_HOME}/.happy"
readonly HAPPY_ACCESS_KEY="${HAPPY_HOME}/access.key"
readonly HAPPY_SETTINGS="${HAPPY_HOME}/settings.json"
readonly HAPPY_DAEMON_STATE="${HAPPY_HOME}/daemon.state.json"

readonly OPENROUTER_ENV="${STATE_DIR}/openrouter.env"
readonly OPENROUTER_PROFILE="${DEV_HOME}/.codex/openrouter.config.toml"
readonly OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex-openrouter"
readonly LEGACY_OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex"

readonly NODE_MAJOR="24"

# Mirrors the version manifest embedded in install.sh / devbox/versions.env.
readonly DEVBOX_VERSION="1.0.0"
readonly ERLANG_VERSION="29.0.5"
readonly ELIXIR_VERSION="1.20.3"
readonly PHOENIX_VERSION="1.8.9"
readonly CODEX_VERSION="0.147.0"
readonly CLAUDE_VERSION="2.1.233"
readonly HAPPY_VERSION="1.2.0"

readonly PACKAGE_NAME_PATTERN='^[a-z0-9][a-z0-9+.-]*$'

readonly DEFAULT_UPDATE_BRANCH="master"
readonly DEFAULT_REPO_URL="https://raw.githubusercontent.com/c4kingpin/Scripts"

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

  doctor
      Validate the development environment.

  update [branch]
      Re-run installer from GitHub. Default branch: master.

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

  install \
    -d \
    -m 0700 \
    -o "$DEV_USER" \
    -g "$DEV_USER" \
    "${DEV_HOME}/.ssh"

  printf '%s\n' \
    "$public_key" \
    >"$SSH_KEY_FILE"

  chown \
    "$DEV_USER:$DEV_USER" \
    "$SSH_KEY_FILE"

  chmod \
    0600 \
    "$SSH_KEY_FILE"

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

  install \
    -d \
    -m 0700 \
    -o "$DEV_USER" \
    -g "$DEV_USER" \
    "$STATE_DIR"

  : >"$SSH_DISABLED_MARKER"

  chown \
    "$DEV_USER:$DEV_USER" \
    "$SSH_DISABLED_MARKER"

  chmod \
    0600 \
    "$SSH_DISABLED_MARKER"

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

show_version() {
  cat <<EOF
DevBox:        ${DEVBOX_VERSION}
Node:          ${NODE_MAJOR}
Erlang:        ${ERLANG_VERSION}
Elixir:        ${ELIXIR_VERSION}
Phoenix:       ${PHOENIX_VERSION}
Codex CLI:     ${CODEX_VERSION}
Claude Code:   ${CLAUDE_VERSION}
Happy:         ${HAPPY_VERSION}
EOF
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


SSH:

  devbox ssh status
  devbox ssh setup
  devbox ssh disable

DevBox SSH configuration applies only to user "dev" and does not intentionally
change root/admin SSH policy.
EOF
}

# P1.2: install.sh records the optional features (elixir, postgres) a box
# was actually installed with in FEATURES_FILE. No file means the box
# predates that (or predates the feature system entirely), so every check
# runs, matching pre-P1.2 behavior.
feature_was_installed() {
  [[ -r "$FEATURES_FILE" ]] || return 0
  grep -Fqw "$1" "$FEATURES_FILE"
}

doctor() {
  local command
  local status=0
  local happy_version=""

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
    else
      warn "PostgreSQL service is not active"
      status=1
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
  else
    warn "Codex CLI is not authenticated (run: devbox auth login)"
  fi

  if run_as_dev \
    bash \
    -lc \
    'claude auth status >/dev/null 2>&1'; then

    ok "Claude CLI is authenticated"
  else
    warn "Claude CLI is not authenticated (run: devbox auth login)"
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
  else
    warn "Happy daemon is not running"
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

  return "$status"
}

update_devbox() {
  require_root

  local branch="${1:-$DEFAULT_UPDATE_BRANCH}"
  local repo_url="${DEVBOX_REPO_URL:-$DEFAULT_REPO_URL}"
  local installer_url="${repo_url%/}/${branch}/devbox/install.sh"
  local installer

  installer="$(mktemp)"

  info "Downloading installer from branch '${branch}'"

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

  info "Re-running installer"

  DEVBOX_REPO_URL="$repo_url" \
    bash "$installer"

  rm \
    -f \
    "$installer"

  ok "Updated from branch '${branch}'"

  doctor
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

    doctor:)
      doctor
      ;;

    update:*)
      update_devbox "$subcommand"
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
