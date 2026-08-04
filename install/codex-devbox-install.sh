#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jörn Siedentopf (c4kingpin)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openai/codex

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
NODE_VERSION="24"
ERLANG_VERSION="28.4"
ELIXIR_VERSION="1.20.2"
PHOENIX_VERSION="1.8.9"
CODEX_AUTONOMY="${CODEX_AUTONOMY:-balanced}"

run_as_dev() {
  runuser -u "$DEV_USER" -- env \
    HOME="$DEV_HOME" \
    USER="$DEV_USER" \
    LOGNAME="$DEV_USER" \
    PATH="${DEV_HOME}/.local/share/mise/shims:${DEV_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

msg_info "Installing Dependencies"
$STD apt install -y --no-install-recommends \
  autoconf \
  bash-completion \
  build-essential \
  ca-certificates \
  curl \
  fd-find \
  git \
  git-lfs \
  gh \
  inotify-tools \
  jq \
  less \
  libncurses-dev \
  libssl-dev \
  nano \
  openssh-server \
  openssl \
  pipx \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep \
  rsync \
  shellcheck \
  sudo \
  tmux \
  unattended-upgrades \
  unzip \
  vim \
  wget \
  xz-utils \
  zip
msg_ok "Installed Dependencies"

NODE_VERSION="$NODE_VERSION" setup_nodejs
setup_postgresql

msg_info "Creating Developer User"
if ! id "$DEV_USER" >/dev/null 2>&1; then
  useradd --create-home --user-group --shell /bin/bash "$DEV_USER"
fi
random_password="$(openssl rand -hex 32)"
password_hash="$(openssl passwd -6 "$random_password")"
usermod --password "$password_hash" "$DEV_USER"
unset random_password password_hash
install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" \
  "${DEV_HOME}/.ssh" \
  "${DEV_HOME}/.codex" \
  "${DEV_HOME}/.config" \
  "${DEV_HOME}/.config/codex-devbox" \
  "${DEV_HOME}/.cache"
install -d -m 0755 -o "$DEV_USER" -g "$DEV_USER" \
  "${DEV_HOME}/.local" \
  "${DEV_HOME}/.local/bin" \
  "${DEV_HOME}/workspace"
for developer_dir in \
  "${DEV_HOME}/.config" \
  "${DEV_HOME}/.cache" \
  "${DEV_HOME}/.local"; do
  if ! run_as_dev test -w "$developer_dir"; then
    msg_error "Developer directory is not writable: ${developer_dir}"
    exit 1
  fi
done
msg_ok "Created Developer User"

msg_info "Installing Codex CLI"
$STD npm install --global @openai/codex@latest
msg_ok "Installed Codex CLI"

msg_info "Installing Erlang, Elixir and Phoenix"
mise_installer="/tmp/codex-devbox-mise-install.sh"
CURL_RETRIES=5 CURL_TIMEOUT=300 CURL_CONNECT_TO=15 \
  curl_with_retry "https://mise.run" "$mise_installer"
chmod 0755 "$mise_installer"
run_as_dev env MISE_INSTALL_PATH="${DEV_HOME}/.local/bin/mise" sh "$mise_installer"
rm -f "$mise_installer"
run_as_dev env \
  MISE_ERLANG_COMPILE=true \
  KERL_CONFIGURE_OPTIONS="--without-javac --without-wx --without-odbc" \
  "${DEV_HOME}/.local/bin/mise" use --global "erlang@${ERLANG_VERSION}"
run_as_dev "${DEV_HOME}/.local/bin/mise" use --global "elixir@${ELIXIR_VERSION}"
run_as_dev "${DEV_HOME}/.local/bin/mise" reshim
run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- mix local.hex --force
run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- mix local.rebar --force
run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- \
  mix archive.install hex phx_new "$PHOENIX_VERSION" --force
msg_ok "Installed Erlang, Elixir and Phoenix"

PG_DB_NAME="devbox"
PG_DB_USER="dev"
setup_postgresql_db

msg_info "Configuring PostgreSQL Development Access"
runuser -u postgres -- psql \
  --set ON_ERROR_STOP=on \
  --command "ALTER ROLE ${PG_DB_USER} CREATEDB;"
cat <<EOF >"${DEV_HOME}/.pgpass"
127.0.0.1:5432:*:${PG_DB_USER}:${PG_DB_PASS}
localhost:5432:*:${PG_DB_USER}:${PG_DB_PASS}
EOF
cat <<EOF >"${DEV_HOME}/.config/codex-devbox/postgres.env"
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=${PG_DB_USER}
PGPASSWORD=${PG_DB_PASS}
PGDATABASE=${PG_DB_NAME}
DATABASE_URL=ecto://${PG_DB_USER}:${PG_DB_PASS}@127.0.0.1/${PG_DB_NAME}
EOF
chown "$DEV_USER:$DEV_USER" \
  "${DEV_HOME}/.pgpass" \
  "${DEV_HOME}/.config/codex-devbox/postgres.env"
chmod 0600 \
  "${DEV_HOME}/.pgpass" \
  "${DEV_HOME}/.config/codex-devbox/postgres.env"
msg_ok "Configured PostgreSQL Development Access"

msg_info "Configuring Development Environment"
fd_binary="$(command -v fdfind || true)"
if [[ -z "$fd_binary" && -x /usr/lib/cargo/bin/fd ]]; then
  fd_binary="/usr/lib/cargo/bin/fd"
fi
if [[ -z "$fd_binary" ]]; then
  msg_error "No fd binary found"
fi
ln -sfn "$fd_binary" /usr/local/bin/fd

cat <<'EOF' >/etc/profile.d/codex-devbox.sh
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/bin:$PATH"
EOF
chmod 0644 /etc/profile.d/codex-devbox.sh

cat <<'EOF' >"${DEV_HOME}/.codex/AGENTS.md"
# Devbox working agreements

- Follow repository-specific `AGENTS.md` files and project conventions.
- Work on a task branch; never push directly to the default branch.
- Run the relevant tests and inspect the diff before publishing changes.
- Create focused commits and draft pull requests when GitHub is authenticated.
- Never commit credentials, tokens, `.env` files, or generated secrets.
- Never force-push unless the user explicitly requests it.
EOF

case "$CODEX_AUTONOMY" in
controlled)
  codex_approval_policy="untrusted"
  codex_sandbox_mode="read-only"
  codex_network_access=""
  ;;
balanced)
  codex_approval_policy="on-request"
  codex_sandbox_mode="workspace-write"
  codex_network_access="false"
  ;;
autonomous)
  codex_approval_policy="never"
  codex_sandbox_mode="workspace-write"
  codex_network_access="true"
  ;;
full-access)
  codex_approval_policy="never"
  codex_sandbox_mode="danger-full-access"
  codex_network_access=""
  ;;
*)
  msg_error "Invalid Codex autonomy profile: ${CODEX_AUTONOMY}"
  ;;
esac

cat <<EOF >"${DEV_HOME}/.codex/config.toml"
# Managed by the Codex DevBox installer.
# Change these values at any time to adjust Codex autonomy.
approval_policy = "${codex_approval_policy}"
sandbox_mode = "${codex_sandbox_mode}"
EOF

if [[ -n "$codex_network_access" ]]; then
  cat <<EOF >>"${DEV_HOME}/.codex/config.toml"

[sandbox_workspace_write]
network_access = ${codex_network_access}
EOF
fi

cat <<'EOF' >>"${DEV_HOME}/.bashrc"

# Codex Dev Box
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/bin:$PATH"
if [[ $- == *i* ]] && command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
if [[ $- == *i* && -d "$HOME/workspace" ]]; then
  cd "$HOME/workspace"
fi
if [[ $- == *i* && -t 0 && -t 1 ]] &&
  [[ ! -e "$HOME/.config/codex-devbox/onboarding-complete" ]] &&
  command -v codex-devbox >/dev/null 2>&1; then
  codex-devbox onboard || true
fi
EOF

chown "$DEV_USER:$DEV_USER" \
  "${DEV_HOME}/.bashrc" \
  "${DEV_HOME}/.codex/AGENTS.md" \
  "${DEV_HOME}/.codex/config.toml"
chmod 0644 \
  "${DEV_HOME}/.bashrc" \
  "${DEV_HOME}/.codex/AGENTS.md"
chmod 0600 "${DEV_HOME}/.codex/config.toml"

run_as_dev git lfs install --skip-repo
run_as_dev git config --global init.defaultBranch main
run_as_dev git config --global pull.ff only
run_as_dev git config --global push.autoSetupRemote true
msg_ok "Configured Development Environment"

msg_info "Installing Codex Dev Box Manager"
cat <<'MANAGER' >/usr/local/bin/codex-devbox
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly DEV_USER="dev"
readonly DEV_HOME="/home/${DEV_USER}"
readonly STATE_DIR="${DEV_HOME}/.config/codex-devbox"
readonly ONBOARDING_MARKER="${STATE_DIR}/onboarding-complete"
readonly SSH_CONFIG="/etc/ssh/sshd_config.d/00-codex-devbox.conf"
readonly SSH_KEY_FILE="${DEV_HOME}/.ssh/authorized_keys"
readonly OPENROUTER_ENV="${STATE_DIR}/openrouter.env"
readonly OPENROUTER_PROFILE="${DEV_HOME}/.codex/openrouter.config.toml"
readonly OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex-openrouter"
readonly LEGACY_OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex"
readonly NODE_MAJOR="24"
readonly ERLANG_VERSION="28.4"
readonly ELIXIR_VERSION="1.20.2"
readonly PHOENIX_VERSION="1.8.9"

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
Usage: codex-devbox COMMAND [SUBCOMMAND]

Commands:
  onboard             Run the interactive first-login onboarding
  ssh status          Show inbound SSH status
  ssh setup           Import a client public key and enable SSH
  ssh disable         Disable the SSH listener
  auth status         Show Codex CLI authentication status
  auth login          Authenticate Codex CLI with the device-code flow
  auth logout         Remove the Codex CLI authentication
  openrouter status   Show OpenRouter configuration status
  openrouter setup    Configure codex-openrouter as a fallback
  openrouter disable  Stop using OpenRouter and remove its stored API key
  github status       Show GitHub authentication and Git identity
  github setup        Configure GitHub authentication and Git identity
  keys status         Show the Dev Box identity key
  keys generate       Generate an Ed25519 identity key for outbound access
  keys upload-github  Upload the identity key to the authenticated GitHub account
  remote-info         Explain the supported ChatGPT mobile connection path
  doctor              Validate the installed development environment
  update              Update OS packages, Codex CLI and the managed toolchain
  help                Show this help
EOF
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "This command must run as root."
}

require_dev() {
  [[ "$EUID" -ne 0 && "$(id -un)" == "$DEV_USER" ]] ||
    die "Run this command as ${DEV_USER}."
}

run_as_dev() {
  if [[ "$EUID" -eq 0 ]]; then
    runuser -u "$DEV_USER" -- env \
      HOME="$DEV_HOME" \
      USER="$DEV_USER" \
      LOGNAME="$DEV_USER" \
      PATH="${DEV_HOME}/.local/share/mise/shims:${DEV_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
      "$@"
  else
    "$@"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-yes}"
  local answer=""

  if [[ "$default" == "yes" ]]; then
    read -r -p "${prompt} [Y/n] " answer || answer="n"
    [[ -z "$answer" || "${answer,,}" =~ ^(y|yes|j|ja)$ ]]
  else
    read -r -p "${prompt} [y/N] " answer || answer="n"
    [[ "${answer,,}" =~ ^(y|yes|j|ja)$ ]]
  fi
}

validate_public_key() {
  local key="$1"
  local key_file

  [[ -n "$key" && "$key" != *$'\n'* && "$key" != *$'\r'* ]] || return 1
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] ||
    return 1

  key_file="$(mktemp)"
  chmod 0600 "$key_file"
  printf '%s\n' "$key" >"$key_file"
  local status
  if ssh-keygen -l -f "$key_file" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  rm -f "$key_file"
  return "$status"
}

write_ssh_config() {
  require_root
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat <<EOF >"$SSH_CONFIG"
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers ${DEV_USER}
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
GatewayPorts no
UseDNS no
LoginGraceTime 30
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
  chmod 0644 "$SSH_CONFIG"
  install -d -m 0755 /run/sshd
  /usr/sbin/sshd -t
}

ssh_status() {
  local key_status="not configured"
  local listener_status="disabled"

  [[ -s "$SSH_KEY_FILE" ]] && key_status="configured"
  if systemctl is-active --quiet ssh.service ||
    systemctl is-active --quiet ssh.socket; then
    listener_status="enabled"
  fi

  printf 'Public key: %s\n' "$key_status"
  printf 'SSH listener: %s\n' "$listener_status"
  if [[ -s "$SSH_KEY_FILE" ]]; then
    ssh-keygen -l -f "$SSH_KEY_FILE"
  fi
}

ssh_setup() {
  require_root
  [[ -t 0 && -t 1 ]] || die "SSH setup requires an interactive terminal."

  cat <<'EOF'
Create the private key on the Mac, Windows PC, or SSH client that will access
this Dev Box. Paste only its public .pub line here. A private client key must
never be generated or stored on the Dev Box.
EOF

  local public_key=""
  read -r -p "Client public key: " public_key
  validate_public_key "$public_key" || die "The public key is invalid."

  install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "${DEV_HOME}/.ssh"
  printf '%s\n' "$public_key" >"$SSH_KEY_FILE"
  chown "$DEV_USER:$DEV_USER" "$SSH_KEY_FILE"
  chmod 0600 "$SSH_KEY_FILE"
  write_ssh_config
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl enable --now ssh.service
  ok "SSH enabled for ${DEV_USER}"
  ssh-keygen -l -f "$SSH_KEY_FILE"
}

ssh_disable() {
  require_root
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl disable --now ssh.service >/dev/null 2>&1 || true
  ok "SSH listener disabled; authorized_keys was retained."
}

codex_auth_status() {
  require_dev
  codex login status
}

codex_auth_login() {
  require_dev
  codex login --device-auth
  if [[ -f "${HOME}/.codex/auth.json" ]]; then
    chmod 0600 "${HOME}/.codex/auth.json"
  fi
  codex_auth_status
}

codex_auth_logout() {
  require_dev
  codex logout
  ok "Codex CLI authentication removed"
}

is_managed_openrouter_file() {
  local path="$1"

  [[ -f "$path" ]] &&
    head -n 2 "$path" | grep -Fq "Managed by codex-devbox openrouter setup"
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
    model="$(sed -n 's/^model = "\(.*\)"$/\1/p' "$OPENROUTER_PROFILE")"
    ok "Codex OpenRouter profile (${model:-unknown model})"
  else
    warn "Codex OpenRouter profile is not configured"
    status=1
  fi

  if is_managed_openrouter_file "$LEGACY_OPENROUTER_WRAPPER"; then
    warn "Legacy setup still routes codex through OpenRouter; run setup again"
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

  for path in "$OPENROUTER_ENV" "$OPENROUTER_PROFILE" "$OPENROUTER_WRAPPER"; do
    if [[ -e "$path" ]] && ! is_managed_openrouter_file "$path"; then
      die "Refusing to overwrite unmanaged file: ${path}"
    fi
  done

  read -r -s -p "OpenRouter API key: " api_key
  printf '\n'
  [[ "$api_key" == sk-or-* ]] ||
    die "The API key must start with sk-or-."

  read -r -p "OpenRouter model [~openai/gpt-latest]: " model
  model="${model:-~openai/gpt-latest}"
  [[ "$model" =~ ^[A-Za-z0-9._~:/-]+$ ]] ||
    die "The OpenRouter model ID is invalid."

  if is_managed_openrouter_file "$LEGACY_OPENROUTER_WRAPPER"; then
    rm -f "$LEGACY_OPENROUTER_WRAPPER"
  fi

  install -d -m 0700 "$STATE_DIR" "${DEV_HOME}/.codex" \
    "${DEV_HOME}/.local/bin"

  {
    printf '# Managed by codex-devbox openrouter setup\n'
    printf 'export OPENROUTER_API_KEY=%q\n' "$api_key"
  } >"$OPENROUTER_ENV"
  chmod 0600 "$OPENROUTER_ENV"

  cat >"$OPENROUTER_PROFILE" <<EOF
# Managed by codex-devbox openrouter setup
model = "${model}"
model_provider = "openrouter"

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
EOF
  chmod 0600 "$OPENROUTER_PROFILE"

  cat >"$OPENROUTER_WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Managed by codex-devbox openrouter setup
set -Eeuo pipefail

readonly openrouter_env="${HOME}/.config/codex-devbox/openrouter.env"
[[ -r "$openrouter_env" ]] || {
  printf 'error - OpenRouter API key is not configured\n' >&2
  exit 1
}
# shellcheck source=/dev/null
source "$openrouter_env"

system_codex="$(PATH=/usr/local/bin:/usr/bin:/bin command -v codex || true)"
[[ -n "$system_codex" && "$system_codex" != "$0" ]] || {
  printf 'error - System Codex CLI was not found\n' >&2
  exit 1
}
exec "$system_codex" --profile openrouter "$@"
EOF
  chmod 0700 "$OPENROUTER_WRAPPER"

  unset api_key
  ok "OpenRouter fallback configured"
  info "Use codex normally for ChatGPT, then codex-openrouter as a fallback."
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
      rm -f "$path"
    elif [[ -e "$path" ]]; then
      warn "Retained unmanaged file: ${path}"
    fi
  done
  ok "OpenRouter disabled and its managed API key removed"
}

github_status() {
  require_dev
  local status=0

  if gh auth status --hostname github.com >/dev/null 2>&1; then
    ok "GitHub authentication"
  else
    warn "GitHub is not authenticated"
    status=1
  fi
  if [[ -n "$(git config --global user.name || true)" ]] &&
    [[ -n "$(git config --global user.email || true)" ]]; then
    printf 'Git name: %s\n' "$(git config --global user.name)"
    printf 'Git email: %s\n' "$(git config --global user.email)"
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

  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    gh auth login \
      --hostname github.com \
      --git-protocol https \
      --web
  fi
  gh auth setup-git --hostname github.com

  account_login="$(gh api user --jq '.login')"
  account_id="$(gh api user --jq '.id')"
  default_name="$(gh api user --jq '.name // .login')"
  default_email="${account_id}+${account_login}@users.noreply.github.com"

  read -r -p "Git commit name [${default_name}]: " git_name
  read -r -p "Git commit email [${default_email}]: " git_email
  git config --global user.name "${git_name:-$default_name}"
  git config --global user.email "${git_email:-$default_email}"
  git config --global credential.https://github.com.helper ""
  git config --global --add \
    credential.https://github.com.helper \
    "!/usr/bin/gh auth git-credential"
  ok "GitHub and Git identity configured"
}

keys_status() {
  require_dev
  local public_key="${HOME}/.ssh/id_ed25519.pub"

  if [[ ! -s "$public_key" ]]; then
    warn "No Dev Box identity key exists"
    return 1
  fi
  ssh-keygen -l -f "$public_key"
  printf '\n%s\n' "$(cat "$public_key")"
}

keys_generate() {
  require_dev
  local private_key="${HOME}/.ssh/id_ed25519"

  install -d -m 0700 "${HOME}/.ssh"
  if [[ -e "$private_key" || -e "${private_key}.pub" ]]; then
    warn "Identity key already exists"
    keys_status
    return
  fi

  info "Generating an outbound Ed25519 identity key"
  ssh-keygen \
    -t ed25519 \
    -a 100 \
    -C "${DEV_USER}@$(hostname)" \
    -f "$private_key"
  chmod 0600 "$private_key"
  chmod 0644 "${private_key}.pub"
  keys_status
}

keys_upload_github() {
  require_dev
  local public_key="${HOME}/.ssh/id_ed25519.pub"

  [[ -s "$public_key" ]] || die "Generate the identity key first."
  gh auth status --hostname github.com >/dev/null 2>&1 ||
    die "Configure GitHub first."
  gh ssh-key add "$public_key" --title "$(hostname)-codex-devbox"
  ok "Uploaded identity key to GitHub"
}

remote_info() {
  cat <<'EOF'
Supported ChatGPT mobile path:

  ChatGPT on iOS
    -> paired ChatGPT desktop app on macOS or Windows
    -> SSH connection configured by that desktop app
    -> this Codex Dev Box

Remote setup starts in the ChatGPT desktop app. It cannot be started from the
Codex CLI. Add this Dev Box under Settings > Connections > SSH and select a
project below /home/dev/workspace.

Without SSH the Dev Box remains available from Proxmox:

  pct enter <CTID>
  sudo -iu dev
EOF
}

doctor() {
  local command
  local status=0
  local commands=(
    codex
    elixir
    erl
    fd
    gh
    git
    mix
    node
    npm
    psql
    python3
    rg
  )

  for command in "${commands[@]}"; do
    if run_as_dev sh -lc "command -v ${command} >/dev/null 2>&1"; then
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
  if systemctl is-active --quiet postgresql.service; then
    ok "PostgreSQL service"
  else
    warn "PostgreSQL service is not active"
    status=1
  fi

  run_as_dev codex --version || status=1
  run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- elixir --version ||
    status=1
  run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- mix phx.new --version ||
    status=1
  ssh_status
  return "$status"
}

update_devbox() {
  require_root
  export DEBIAN_FRONTEND=noninteractive

  info "Updating operating system"
  apt-get update
  apt-get -y full-upgrade

  info "Updating Codex CLI"
  npm install --global @openai/codex@latest

  info "Ensuring managed Erlang, Elixir and Phoenix versions"
  apt-get install -y --no-install-recommends \
    autoconf \
    build-essential \
    libncurses-dev \
    libssl-dev
  run_as_dev env \
    MISE_ERLANG_COMPILE=true \
    KERL_CONFIGURE_OPTIONS="--without-javac --without-wx --without-odbc" \
    "${DEV_HOME}/.local/bin/mise" use --global "erlang@${ERLANG_VERSION}"
  run_as_dev "${DEV_HOME}/.local/bin/mise" use --global \
    "elixir@${ELIXIR_VERSION}"
  run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- \
    mix archive.install hex phx_new "$PHOENIX_VERSION" --force
  run_as_dev "${DEV_HOME}/.local/bin/mise" reshim

  apt-get -y autoremove
  apt-get clean
  doctor
}

onboard() {
  require_dev
  [[ -t 0 && -t 1 ]] || return 0

  install -d -m 0700 "$STATE_DIR"
  cat <<'EOF'
Codex Dev Box onboarding

1. Optional inbound SSH access for the ChatGPT desktop host or another client
2. Optional Codex CLI authentication using a device code
3. Optional OpenRouter API key and model for Codex
4. GitHub authentication and Git commit identity
5. Optional outbound Ed25519 identity key
6. Environment diagnostics and supported ChatGPT mobile instructions
EOF

  if prompt_yes_no "Configure inbound SSH now?"; then
    sudo -n /usr/local/bin/codex-devbox ssh setup
  fi
  if prompt_yes_no "Authenticate the Codex CLI now?"; then
    codex_auth_login
  fi
  if prompt_yes_no "Configure OpenRouter as a Codex fallback?" "no"; then
    openrouter_setup
  fi
  if prompt_yes_no "Configure GitHub now?"; then
    github_setup
  fi
  if prompt_yes_no "Generate a Dev Box identity key?" "no"; then
    keys_generate
    if gh auth status --hostname github.com >/dev/null 2>&1 &&
      prompt_yes_no "Upload this public key to GitHub?" "no"; then
      keys_upload_github
    fi
  fi

  remote_info
  doctor || warn "Doctor found optional or required items that need attention"
  : >"$ONBOARDING_MARKER"
  chmod 0600 "$ONBOARDING_MARKER"
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
    auth:status)
      codex_auth_status
      ;;
    auth:login)
      codex_auth_login
      ;;
    auth:logout)
      codex_auth_logout
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
    update:)
      update_devbox
      ;;
    help:|-h:|--help:)
      usage
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
MANAGER
chmod 0755 /usr/local/bin/codex-devbox

cat <<EOF >/etc/sudoers.d/90-codex-devbox
${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/codex-devbox ssh setup
${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/codex-devbox ssh disable
EOF
chmod 0440 /etc/sudoers.d/90-codex-devbox
visudo -cf /etc/sudoers.d/90-codex-devbox
msg_ok "Installed Codex Dev Box Manager"

msg_info "Securing SSH"
install -d -m 0755 /etc/ssh/sshd_config.d
cat <<EOF >/etc/ssh/sshd_config.d/00-codex-devbox.conf
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers ${DEV_USER}
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
GatewayPorts no
UseDNS no
LoginGraceTime 30
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
chmod 0644 /etc/ssh/sshd_config.d/00-codex-devbox.conf
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t

if [[ -n "${SSH_AUTHORIZED_KEY:-}" ]]; then
  printf '%s\n' "$SSH_AUTHORIZED_KEY" >"${DEV_HOME}/.ssh/authorized_keys"
  chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.ssh/authorized_keys"
  chmod 0600 "${DEV_HOME}/.ssh/authorized_keys"
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl enable --now ssh.service
else
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl disable --now ssh.service >/dev/null 2>&1 || true
fi
msg_ok "Secured SSH"

msg_info "Enabling Security Updates"
cat <<'EOF' >/etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
msg_ok "Enabled Security Updates"

msg_info "Validating Installation"
node --version
npm --version
codex --version
run_as_dev "${DEV_HOME}/.local/bin/mise" --version
run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- elixir --version
run_as_dev "${DEV_HOME}/.local/bin/mise" exec -- mix phx.new --version
systemctl is-active --quiet postgresql.service
run_as_dev psql \
  --host 127.0.0.1 \
  --username "$PG_DB_USER" \
  --dbname "$PG_DB_NAME" \
  --no-password \
  --command "SELECT 1;" >/dev/null
/usr/local/bin/codex-devbox doctor
msg_ok "Validated Installation"

motd_ssh
customize
cleanup_lxc
