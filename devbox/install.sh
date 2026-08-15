#!/usr/bin/env bash
# Copyright (c) 2021-2026 c4kingpin
# Author: Jörn Siedentopf (c4kingpin)
# License: MIT
#
# Sources:
#   https://github.com/openai/codex
#   https://github.com/anthropics/claude-code
#   https://github.com/slopus/happy
#
# DevBox - standalone Ubuntu LTS LXC installer
#
# Runtime architecture:
#
#   root
#     - OS/package administration
#     - system services
#     - system toolchain
#
#   postgres
#     - PostgreSQL
#
#   dev
#     - Happy
#     - Claude Code
#     - Codex
#     - Git/GitHub
#     - project workspaces
#     - agent credentials
#
# Happy is the primary session/remote layer:
#
#   happy
#   happy claude
#   happy codex
#
# Native Claude and Codex remain installed as backends:
#
#   claude
#   codex
#
# Existing administrative SSH/root access is deliberately NOT restricted.
# DevBox SSH configuration applies only to the "dev" user.
#
# Run as root:
#
#   curl -fsSL \
#     https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh \
#     | bash

set -Eeuo pipefail
umask 022

RD=$'\033[01;31m'
GN=$'\033[1;92m'
YW=$'\033[33m'
CL=$'\033[m'

msg_info() {
  printf '%b\n' "${YW}➜ $*${CL}"
}

msg_ok() {
  printf '%b\n' "${GN}✓ $*${CL}"
}

msg_error() {
  printf '%b\n' "${RD}✗ $*${CL}" >&2
}

error_handler() {
  local exit_code=$?
  local line="${1:-${LINENO}}"

  msg_error "Installation failed at line ${line} (exit code ${exit_code})."
  exit "$exit_code"
}

trap 'error_handler ${LINENO}' ERR

LOG_FILE="$(mktemp /tmp/devbox-install.XXXXXX.log)"
readonly LOG_FILE

silent() {
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    msg_error "Command failed: $*"
    printf '%s\n' "--- last 40 log lines (${LOG_FILE}) ---" >&2
    tail -n 40 "$LOG_FILE" >&2
    return 1
  fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || {
    msg_error "This installer must run as root inside the LXC container."
    exit 1
  }
}

require_supported_os() {
  local os_id=""
  local os_version=""

  command -v apt-get >/dev/null 2>&1 || {
    msg_error "This installer requires Ubuntu LTS (apt-get not found)."
    exit 1
  }

  if [[ -r /etc/os-release ]]; then
    os_id="$(
      . /etc/os-release
      printf '%s' "${ID:-}"
    )"

    os_version="$(
      . /etc/os-release
      printf '%s' "${VERSION_ID:-}"
    )"
  fi

  case "${os_id}-${os_version}" in
    ubuntu-24.04 | ubuntu-22.04 | ubuntu-20.04)
      msg_ok "Supported OS: Ubuntu ${os_version}"
      ;;
    *)
      msg_error "Unsupported OS: ${os_id:-unknown} ${os_version:-unknown}"
      msg_error "Ubuntu 24.04 LTS is recommended."
      msg_error "Ubuntu 22.04 and 20.04 are also supported."
      exit 1
      ;;
  esac
}

# Older DevBox revisions wrote a global SSH policy containing:
#
#   PermitRootLogin no
#   AllowUsers dev
#
# That could block new administrative root SSH sessions. Remove only a file
# that clearly matches the legacy DevBox policy. Other SSH configuration is
# never modified here.
repair_legacy_ssh_policy() {
  local ssh_config="/etc/ssh/sshd_config.d/00-devbox.conf"

  [[ -f "$ssh_config" ]] || return 0

  if grep -Eq \
    '^(PermitRootLogin no|AllowUsers dev|AuthenticationMethods publickey)$' \
    "$ssh_config"; then

    msg_info "Removing legacy global DevBox SSH restrictions"

    rm -f "$ssh_config"

    if command -v sshd >/dev/null 2>&1; then
      install -d -m 0755 /run/sshd
      /usr/sbin/sshd -t

      if systemctl is-active --quiet ssh.service 2>/dev/null; then
        systemctl reload ssh.service
      fi
    fi

    msg_ok "Removed legacy SSH restrictions; administrative SSH policy preserved"
  fi
}

network_check() {
  msg_info "Checking network connectivity"

  if ! curl \
    -fsSL \
    --connect-timeout 5 \
    --max-time 10 \
    https://github.com \
    >/dev/null 2>&1; then

    msg_error "No network connectivity to github.com."
    exit 1
  fi

  msg_ok "Network connectivity confirmed"
}

update_os() {
  msg_info "Updating OS package lists"

  export DEBIAN_FRONTEND=noninteractive

  silent apt-get update
  silent apt-get -y upgrade

  msg_ok "Updated OS packages"
}

curl_with_retry() {
  local url="$1"
  local destination="$2"

  curl \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 15 \
    --max-time 300 \
    --retry 5 \
    --retry-all-errors \
    --retry-connrefused \
    --fail \
    --silent \
    --show-error \
    --location \
    --output "$destination" \
    "$url"
}

require_root
require_supported_os
repair_legacy_ssh_policy
network_check
update_os

readonly DEV_USER="dev"
readonly DEV_HOME="/home/${DEV_USER}"
readonly NODE_VERSION="24"

ERLANG_VERSION="${ERLANG_VERSION:-29.0.5}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.20.3}"
PHOENIX_VERSION="${PHOENIX_VERSION:-1.8.9}"

DEVBOX_REPO_URL="${DEVBOX_REPO_URL:-https://raw.githubusercontent.com/c4kingpin/Scripts}"

run_as_dev() (
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

select_autonomy() {
  local requested="${DEVBOX_AUTONOMY:-}"

  if [[ -f "${DEV_HOME}/.codex/config.toml" ||
        -f "${DEV_HOME}/.claude/settings.json" ]]; then

    DEVBOX_AUTONOMY="${requested:-balanced}"

    msg_ok "Existing agent configuration preserved; skipping autonomy prompt"
    return
  fi

  case "$requested" in
    controlled | balanced | autonomous | full-access)
      DEVBOX_AUTONOMY="$requested"
      ;;

    "")
      if [[ -t 0 && -t 1 ]]; then
        cat <<'EOF'

How autonomously may Codex and Claude work?

  1) Controlled
     Read-only; approve edits and commands.

  2) Balanced
     Workspace edits allowed; external access asks.
     Recommended.

  3) Autonomous
     Workspace and network without approval prompts.

  4) Full access
     No agent sandbox or prompts; LXC boundary only.

EOF

        local choice=""

        read -r \
          -p "Choice [2]: " \
          choice

        case "${choice:-2}" in
          1) DEVBOX_AUTONOMY="controlled" ;;
          2) DEVBOX_AUTONOMY="balanced" ;;
          3) DEVBOX_AUTONOMY="autonomous" ;;
          4) DEVBOX_AUTONOMY="full-access" ;;
          *) DEVBOX_AUTONOMY="balanced" ;;
        esac
      else
        DEVBOX_AUTONOMY="balanced"
      fi
      ;;

    *)
      msg_error "Invalid DEVBOX_AUTONOMY: ${requested}"
      exit 1
      ;;
  esac

  msg_ok "Agent autonomy profile: ${DEVBOX_AUTONOMY}"
}

select_autonomy

msg_info "Ensuring Ubuntu universe component is enabled"

if apt-cache policy 2>/dev/null | grep -q universe; then
  msg_ok "universe component already enabled"
else
  silent apt-get install \
    -y \
    --no-install-recommends \
    software-properties-common

  silent add-apt-repository \
    -y \
    universe

  silent apt-get update

  msg_ok "Enabled universe component"
fi

msg_info "Installing Dependencies"

silent apt-get install \
  -y \
  --no-install-recommends \
  bash-completion \
  build-essential \
  ca-certificates \
  curl \
  fd-find \
  git \
  git-lfs \
  gh \
  gnupg \
  inotify-tools \
  jq \
  less \
  libssl-dev \
  nano \
  openssh-server \
  openssl \
  pipx \
  postgresql \
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

msg_info "Installing Node.js ${NODE_VERSION}"

if [[ "$(node --version 2>/dev/null || true)" != "v${NODE_VERSION}."* ]]; then
  nodesource_setup="$(mktemp)"

  curl_with_retry \
    "https://deb.nodesource.com/setup_${NODE_VERSION}.x" \
    "$nodesource_setup"

  silent bash "$nodesource_setup"

  rm -f "$nodesource_setup"

  silent apt-get install \
    -y \
    --no-install-recommends \
    nodejs
fi

if [[ "$(node --version)" != "v${NODE_VERSION}."* ]]; then
  msg_error "Unexpected Node.js version: $(node --version 2>/dev/null || echo none)"
  exit 1
fi

msg_ok "Installed Node.js $(node --version)"

msg_info "Enabling PostgreSQL"

systemctl enable \
  --now \
  postgresql.service

msg_ok "Enabled PostgreSQL"

msg_info "Creating Developer User"

if ! id "$DEV_USER" >/dev/null 2>&1; then
  useradd \
    --create-home \
    --user-group \
    --shell /bin/bash \
    "$DEV_USER"

  random_password="$(openssl rand -hex 32)"
  password_hash="$(openssl passwd -6 "$random_password")"

  usermod \
    --password "$password_hash" \
    "$DEV_USER"

  unset random_password
  unset password_hash
fi

if [[ -d "${DEV_HOME}/.config/codex-devbox" &&
      ! -d "${DEV_HOME}/.config/devbox" ]]; then

  msg_info "Migrating state from ~/.config/codex-devbox"

  mv \
    "${DEV_HOME}/.config/codex-devbox" \
    "${DEV_HOME}/.config/devbox"

  msg_ok "Migrated state to ~/.config/devbox"
fi

rm -f \
  /usr/local/bin/codex-devbox \
  /etc/sudoers.d/90-codex-devbox \
  /etc/profile.d/codex-devbox.sh

if [[ -d "${DEV_HOME}/.local/share/mise" ]]; then
  msg_info "Removing previously mise-managed BEAM toolchain"

  rm -rf \
    "${DEV_HOME}/.local/share/mise/installs/erlang" \
    "${DEV_HOME}/.local/share/mise/installs/elixir" \
    "${DEV_HOME}/.local/share/elixir"

  for stale_bin in \
    elixir \
    elixirc \
    iex \
    mix \
    erl \
    erlc \
    escript; do

    rm -f \
      "${DEV_HOME}/.local/share/mise/shims/${stale_bin}" \
      "${DEV_HOME}/.local/bin/${stale_bin}"
  done

  if [[ -f "${DEV_HOME}/.config/mise/config.toml" ]]; then
    sed \
      -i \
      '/^\(erlang\|elixir\) *=/d' \
      "${DEV_HOME}/.config/mise/config.toml"
  fi

  msg_ok "Removed previously mise-managed BEAM toolchain"
fi

install \
  -d \
  -m 0700 \
  -o "$DEV_USER" \
  -g "$DEV_USER" \
  "${DEV_HOME}/.ssh" \
  "${DEV_HOME}/.codex" \
  "${DEV_HOME}/.claude" \
  "${DEV_HOME}/.happy" \
  "${DEV_HOME}/.config" \
  "${DEV_HOME}/.config/devbox" \
  "${DEV_HOME}/.cache"

install \
  -d \
  -m 0755 \
  -o "$DEV_USER" \
  -g "$DEV_USER" \
  "${DEV_HOME}/.local" \
  "${DEV_HOME}/.local/bin" \
  "${DEV_HOME}/workspace"

for developer_dir in \
  "${DEV_HOME}/.config" \
  "${DEV_HOME}/.cache" \
  "${DEV_HOME}/.local" \
  "${DEV_HOME}/.happy" \
  "${DEV_HOME}/workspace"; do

  if ! run_as_dev test -w "$developer_dir"; then
    msg_error "Developer directory is not writable: ${developer_dir}"
    exit 1
  fi
done

msg_ok "Created Developer User"

msg_info "Installing Codex CLI"

silent npm install \
  --global \
  @openai/codex@latest

msg_ok "Installed Codex CLI"

msg_info "Installing Claude Code"

silent npm install \
  --global \
  @anthropic-ai/claude-code@latest

msg_ok "Installed Claude Code"

msg_info "Installing Happy"

silent npm install \
  --global \
  happy@latest

# Do NOT call `happy` or `happy --version` here. Happy can enter its normal
# first-use authentication/pairing path. Validate installation via npm only.
if ! npm list \
  --global \
  --depth=0 \
  happy \
  >/dev/null 2>&1; then

  msg_error "Happy npm package was not installed correctly."
  exit 1
fi

msg_ok "Installed Happy"

msg_info "Installing mise"

mise_installer="/tmp/devbox-mise-install.sh"

curl_with_retry \
  "https://mise.run" \
  "$mise_installer"

chmod 0755 "$mise_installer"

run_as_dev \
  env \
  MISE_INSTALL_PATH="${DEV_HOME}/.local/bin/mise" \
  sh "$mise_installer" \
  >>"$LOG_FILE" 2>&1

rm -f "$mise_installer"

msg_ok "Installed mise"

readonly OTP_ROOT="/opt/devbox/otp"
readonly ELIXIR_ROOT="/opt/devbox/elixir"

ERLANG_OTP_MAJOR="${ERLANG_VERSION%%.*}"

msg_info "Installing Erlang/OTP ${ERLANG_VERSION}"

otp_arch="$(dpkg --print-architecture)"

otp_os="ubuntu-$(
  . /etc/os-release
  printf '%s' "${VERSION_ID}"
)"

otp_tarball="/tmp/devbox-otp.tar.gz"

curl_with_retry \
  "https://builds.hex.pm/builds/otp/${otp_arch}/${otp_os}/OTP-${ERLANG_VERSION}.tar.gz" \
  "$otp_tarball"

rm -rf "$OTP_ROOT"

install \
  -d \
  -m 0755 \
  "$OTP_ROOT"

tar \
  -xzf "$otp_tarball" \
  -C "$OTP_ROOT" \
  --strip-components=1

rm -f "$otp_tarball"

(
  cd "$OTP_ROOT"

  ./Install \
    -minimal \
    "$OTP_ROOT"
) >>"$LOG_FILE" 2>&1

for otp_bin in \
  erl \
  erlc \
  escript \
  epmd \
  dialyzer \
  typer \
  ct_run \
  run_erl \
  to_erl; do

  if [[ -x "${OTP_ROOT}/bin/${otp_bin}" ]]; then
    ln \
      -sfn \
      "${OTP_ROOT}/bin/${otp_bin}" \
      "/usr/local/bin/${otp_bin}"
  fi
done

if [[ ! -f "${DEV_HOME}/.erlang.cookie" ]]; then
  openssl rand \
    -hex 32 \
    >"${DEV_HOME}/.erlang.cookie"
fi

chown \
  "$DEV_USER:$DEV_USER" \
  "${DEV_HOME}/.erlang.cookie"

chmod \
  0400 \
  "${DEV_HOME}/.erlang.cookie"

if ! run_as_dev erl \
  -noshell \
  -eval 'halt(0).'; then

  msg_error "Erlang ${ERLANG_VERSION} was installed but cannot execute BEAM code."
  exit 1
fi

msg_ok "Installed Erlang/OTP ${ERLANG_VERSION}"

msg_info "Installing Elixir ${ELIXIR_VERSION} and Phoenix ${PHOENIX_VERSION}"

elixir_zip="/tmp/devbox-elixir.zip"

curl_with_retry \
  "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${ERLANG_OTP_MAJOR}.zip" \
  "$elixir_zip"

rm -rf "$ELIXIR_ROOT"

install \
  -d \
  -m 0755 \
  "$ELIXIR_ROOT"

unzip \
  -q \
  "$elixir_zip" \
  -d "$ELIXIR_ROOT"

rm -f "$elixir_zip"

chmod \
  0755 \
  "$ELIXIR_ROOT"/bin/*

for elixir_bin in \
  elixir \
  elixirc \
  iex \
  mix; do

  ln \
    -sfn \
    "${ELIXIR_ROOT}/bin/${elixir_bin}" \
    "/usr/local/bin/${elixir_bin}"
done

run_as_dev mix local.hex --force
run_as_dev mix local.rebar --force

run_as_dev mix archive.install \
  hex \
  phx_new \
  "$PHOENIX_VERSION" \
  --force

msg_ok "Installed Elixir ${ELIXIR_VERSION} (OTP ${ERLANG_OTP_MAJOR}) and Phoenix ${PHOENIX_VERSION}"

readonly PG_DB_NAME="devbox"
readonly PG_DB_USER="dev"
readonly PG_ENV_FILE="${DEV_HOME}/.config/devbox/postgres.env"

msg_info "Configuring PostgreSQL Development Access"

if [[ -r "$PG_ENV_FILE" ]] &&
  grep \
    -q \
    '^PGPASSWORD=' \
    "$PG_ENV_FILE"; then

  PG_DB_PASS="$(
    sed \
      -n \
      's/^PGPASSWORD=//p' \
      "$PG_ENV_FILE"
  )"
else
  PG_DB_PASS="$(openssl rand -hex 24)"
fi

if runuser \
  -u postgres \
  -- \
  psql \
    --tuples-only \
    --no-align \
    --command "SELECT 1 FROM pg_roles WHERE rolname = '${PG_DB_USER}';" \
  | grep -q '^1$'; then

  runuser \
    -u postgres \
    -- \
    psql \
      --set ON_ERROR_STOP=on \
      --command "ALTER ROLE ${PG_DB_USER} WITH PASSWORD '${PG_DB_PASS}' CREATEDB;"
else
  runuser \
    -u postgres \
    -- \
    psql \
      --set ON_ERROR_STOP=on \
      --command "CREATE ROLE ${PG_DB_USER} WITH LOGIN PASSWORD '${PG_DB_PASS}' CREATEDB;"
fi

if ! runuser \
  -u postgres \
  -- \
  psql \
    --tuples-only \
    --no-align \
    --command "SELECT 1 FROM pg_database WHERE datname = '${PG_DB_NAME}';" \
  | grep -q '^1$'; then

  runuser \
    -u postgres \
    -- \
    psql \
      --set ON_ERROR_STOP=on \
      --command "CREATE DATABASE ${PG_DB_NAME} OWNER ${PG_DB_USER};"
fi

cat <<EOF >"${DEV_HOME}/.pgpass"
127.0.0.1:5432:*:${PG_DB_USER}:${PG_DB_PASS}
localhost:5432:*:${PG_DB_USER}:${PG_DB_PASS}
EOF

cat <<EOF >"$PG_ENV_FILE"
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=${PG_DB_USER}
PGPASSWORD=${PG_DB_PASS}
PGDATABASE=${PG_DB_NAME}
DATABASE_URL=ecto://${PG_DB_USER}:${PG_DB_PASS}@127.0.0.1/${PG_DB_NAME}
EOF

chown \
  "$DEV_USER:$DEV_USER" \
  "${DEV_HOME}/.pgpass" \
  "$PG_ENV_FILE"

chmod \
  0600 \
  "${DEV_HOME}/.pgpass" \
  "$PG_ENV_FILE"

unset PG_DB_PASS

msg_ok "Configured PostgreSQL Development Access"

msg_info "Configuring Development Environment"

fd_binary="$(command -v fdfind || true)"

if [[ -z "$fd_binary" &&
      -x /usr/lib/cargo/bin/fd ]]; then

  fd_binary="/usr/lib/cargo/bin/fd"
fi

if [[ -z "$fd_binary" ]]; then
  msg_error "No fd binary found."
  exit 1
fi

ln \
  -sfn \
  "$fd_binary" \
  /usr/local/bin/fd

cat <<'EOF' >/etc/profile.d/devbox.sh
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"
EOF

chmod \
  0644 \
  /etc/profile.d/devbox.sh

agent_instructions() {
  cat <<'EOF'
# DevBox working agreements

- Follow repository-specific `AGENTS.md`, `CLAUDE.md`, and project conventions.
- Work on a task branch; never push directly to the default branch.
- Run relevant tests and inspect the diff before publishing changes.
- Create focused commits and draft pull requests when GitHub is authenticated.
- Never commit credentials, tokens, `.env` files, or generated secrets.
- Never inspect credential stores such as `~/.ssh`, `~/.happy/access.key`,
  `~/.codex/auth.json`, `~/.claude/.credentials.json`, or DevBox secret files
  unless the user explicitly requests authentication troubleshooting.
- Never force-push unless the user explicitly requests it.
EOF
}

agent_instructions \
  >"${DEV_HOME}/.codex/AGENTS.md"

agent_instructions \
  >"${DEV_HOME}/.claude/CLAUDE.md"

case "$DEVBOX_AUTONOMY" in
  controlled)
    codex_approval_policy="untrusted"
    codex_sandbox_mode="read-only"
    codex_network_access=""
    claude_default_mode="default"
    ;;

  balanced)
    codex_approval_policy="on-request"
    codex_sandbox_mode="workspace-write"
    codex_network_access="false"
    claude_default_mode="acceptEdits"
    ;;

  autonomous)
    codex_approval_policy="never"
    codex_sandbox_mode="workspace-write"
    codex_network_access="true"
    claude_default_mode="auto"
    ;;

  full-access)
    codex_approval_policy="never"
    codex_sandbox_mode="danger-full-access"
    codex_network_access=""
    claude_default_mode="bypassPermissions"
    ;;
esac

if [[ ! -f "${DEV_HOME}/.codex/config.toml" ]]; then
  cat <<EOF >"${DEV_HOME}/.codex/config.toml"
# Managed by the DevBox installer.
approval_policy = "${codex_approval_policy}"
sandbox_mode = "${codex_sandbox_mode}"
EOF

  if [[ -n "$codex_network_access" ]]; then
    cat <<EOF >>"${DEV_HOME}/.codex/config.toml"

[sandbox_workspace_write]
network_access = ${codex_network_access}
EOF
  fi
else
  msg_info "Preserving existing ~/.codex/config.toml"
fi

if [[ ! -f "${DEV_HOME}/.claude/settings.json" ]]; then
  cat <<EOF >"${DEV_HOME}/.claude/settings.json"
{
  "\$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "defaultMode": "${claude_default_mode}",
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(~/.ssh/**)",
      "Read(~/.pgpass)",
      "Read(~/.happy/access.key)",
      "Read(~/.codex/auth.json)",
      "Read(~/.claude/.credentials.json)",
      "Read(~/.config/devbox/openrouter.env)"
    ]
  }
}
EOF
else
  msg_info "Preserving existing ~/.claude/settings.json"

  if jq \
    empty \
    "${DEV_HOME}/.claude/settings.json" \
    >/dev/null 2>&1; then

    claude_settings_tmp="$(mktemp)"

    jq '
      .permissions = (.permissions // {}) |
      .permissions.deny = (
        (.permissions.deny // [])
        + ["Read(~/.happy/access.key)"]
        | unique
      )
    ' \
      "${DEV_HOME}/.claude/settings.json" \
      >"$claude_settings_tmp"

    cat \
      "$claude_settings_tmp" \
      >"${DEV_HOME}/.claude/settings.json"

    rm -f "$claude_settings_tmp"
  else
    msg_error "Existing ~/.claude/settings.json is invalid JSON."
    msg_error "Happy credential deny rule could not be added."
  fi
fi

if grep \
  -Fq \
  '# Codex Dev Box' \
  "${DEV_HOME}/.bashrc" \
  2>/dev/null; then

  sed \
    -i \
    -e 's/# Codex Dev Box/# DevBox/' \
    -e 's/codex-devbox/devbox/g' \
    "${DEV_HOME}/.bashrc"

  msg_ok "Migrated old DevBox block in ~/.bashrc"
fi

if ! grep \
  -Fq \
  '# DevBox' \
  "${DEV_HOME}/.bashrc" \
  2>/dev/null; then

  cat <<'EOF' >>"${DEV_HOME}/.bashrc"

# DevBox
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

if [[ $- == *i* && -d "$HOME/workspace" ]]; then
  cd "$HOME/workspace"
fi

if [[ $- == *i* && -t 0 && -t 1 ]] &&
  [[ ! -e "$HOME/.config/devbox/onboarding-complete" ]] &&
  command -v devbox >/dev/null 2>&1; then

  devbox onboard || true
fi
EOF
fi

if ! grep \
  -Fq \
  '# DevBox Happy' \
  "${DEV_HOME}/.bashrc" \
  2>/dev/null; then

  cat <<'EOF' >>"${DEV_HOME}/.bashrc"

# DevBox Happy
#
# Happy is the primary session layer.
#
# Native `claude` and `codex` remain untouched because Happy uses them as
# backends and they remain useful for authentication, diagnostics and recovery.

alias hclaude='happy claude'
alias hcodex='happy codex'

# Restart the Happy daemon after a reboot only if Happy was already paired.
# Merely opening a shell must never initiate first-time pairing.
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
        ! kill -0 "$pid" 2>/dev/null; then

        happy daemon start \
          >/dev/null 2>&1 \
          || true
      fi
    fi
  ) >/dev/null 2>&1 &
fi
EOF
fi

chown \
  "$DEV_USER:$DEV_USER" \
  "${DEV_HOME}/.bashrc" \
  "${DEV_HOME}/.codex/AGENTS.md" \
  "${DEV_HOME}/.codex/config.toml" \
  "${DEV_HOME}/.claude/CLAUDE.md" \
  "${DEV_HOME}/.claude/settings.json"

chmod \
  0644 \
  "${DEV_HOME}/.bashrc" \
  "${DEV_HOME}/.codex/AGENTS.md" \
  "${DEV_HOME}/.claude/CLAUDE.md"

chmod \
  0600 \
  "${DEV_HOME}/.codex/config.toml" \
  "${DEV_HOME}/.claude/settings.json"

chmod \
  0700 \
  "${DEV_HOME}/.happy"

run_as_dev git lfs install \
  --skip-repo

run_as_dev git config \
  --global \
  init.defaultBranch \
  main

run_as_dev git config \
  --global \
  pull.ff \
  only

run_as_dev git config \
  --global \
  push.autoSetupRemote \
  true

msg_ok "Configured Development Environment"

msg_info "Installing DevBox Manager"

cat <<'MANAGER' >/usr/local/bin/devbox
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly DEV_USER="dev"
readonly DEV_HOME="/home/${DEV_USER}"

readonly STATE_DIR="${DEV_HOME}/.config/devbox"
readonly ONBOARDING_MARKER="${STATE_DIR}/onboarding-complete"

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
      Show DevBox SSH status for the dev user.

  ssh setup
      Configure public-key SSH login for the dev user.

  ssh disable
      Disable SSH login for the dev user only.
      Existing administrative/root SSH configuration is untouched.

  auth status
      Show Happy, Codex and Claude authentication status.

  auth login
      Authenticate Codex and Claude, pair Happy, then start Happy daemon.

  auth logout
      Sign out of Happy, Codex and Claude.

  openrouter status
      Show OpenRouter fallback configuration.

  openrouter setup
      Configure codex-openrouter as explicit fallback.

  openrouter disable
      Remove managed OpenRouter configuration and API key.

  github status
      Show GitHub authentication and Git identity.

  github setup
      Configure GitHub and Git identity.

  keys status
      Show DevBox outbound SSH identity key.

  keys generate
      Generate an Ed25519 outbound identity key.

  keys upload-github
      Upload the public identity key to GitHub.

  remote-info
      Explain Happy remote access and native agent commands.

  doctor
      Validate the development environment.

  update [branch]
      Re-run the installer from GitHub.
      Defaults to branch "master".

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

  chmod 0600 "$key_file"

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

# Only the dev user's SSH behaviour is managed here.
#
# enabled:
#   - dev may authenticate using public keys
#   - passwords and keyboard-interactive auth are disabled for dev
#   - root and every other account inherit the existing server policy
#
# disabled:
#   - DenyUsers dev
#   - root and every other account remain untouched
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
# This file intentionally applies only to user "dev".
# Administrative/root SSH configuration is not modified.

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
# Administrative/root SSH configuration is not modified.

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

  install -d -m 0755 /run/sshd
  /usr/sbin/sshd -t
}

apply_sshd_config() {
  require_root

  local activate_if_inactive="${1:-no}"

  install -d -m 0755 /run/sshd
  /usr/sbin/sshd -t

  if systemctl is-active \
    --quiet \
    ssh.service; then

    # Reload does not terminate established SSH sessions.
    systemctl reload ssh.service

  elif systemctl is-active \
    --quiet \
    ssh.socket; then

    # Socket-activated sshd processes read the current configuration for new
    # connections. Nothing needs to be restarted here.
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

Create the private key on the Mac, Windows PC, or other SSH client that will
access this DevBox.

Paste only its public .pub line here.

A private client key must never be generated or stored on the DevBox.
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
    info "Open the printed URL on another device if necessary."

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
        warn "Happy daemon could not be started."
        warn "Run manually: happy daemon start"
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

  ok "Signed out of Happy, Codex and Claude"
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

  info "Primary Codex session:"
  info "  happy codex"
  info ""
  info "Native Codex:"
  info "  codex"
  info ""
  info "Explicit OpenRouter fallback:"
  info "  codex-openrouter"

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

    gh auth login \
      --hostname github.com \
      --git-protocol https \
      --web
  fi

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

  git config \
    --global \
    credential.https://github.com.helper \
    ""

  git config \
    --global \
    --add \
    credential.https://github.com.helper \
    "!/usr/bin/gh auth git-credential"

  ok "GitHub and Git identity configured"
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
              | encrypted Happy connection
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


Primary commands

  happy
      Start Claude through Happy.

  happy claude
      Explicit Claude session through Happy.

  happy codex
      Start Codex through Happy.

  hclaude
      Alias for happy claude.

  hcodex
      Alias for happy codex.


Native backends remain installed

  claude
  codex


Happy management

  happy auth status
  happy auth login

  happy daemon status
  happy daemon start
  happy daemon stop
  happy daemon list


DevBox authentication

  devbox auth status
  devbox auth login
  devbox auth logout

`devbox auth login` authenticates Codex and Claude, then explicitly launches
Happy's pairing flow.

Happy asking you to connect/pair during that step is expected.

Simply installing or validating the DevBox does NOT intentionally launch
Happy's pairing flow.


SSH

DevBox manages SSH policy only for user "dev".

It does NOT set:

  PermitRootLogin no
  AllowUsers dev

and therefore does not intentionally restrict existing administrative/root
SSH access.

Configure dev SSH:

  devbox ssh setup

Disable dev SSH only:

  devbox ssh disable

Inspect:

  devbox ssh status
EOF
}

doctor() {
  local command
  local status=0
  local happy_version=""

  local commands=(
    claude
    codex
    happy
    elixir
    erl
    fd
    gh
    git
    jq
    mix
    node
    npm
    psql
    python3
    rg
  )

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

  if systemctl is-active \
    --quiet \
    postgresql.service; then

    ok "PostgreSQL service"
  else
    warn "PostgreSQL service is not active"
    status=1
  fi

  if run_as_dev erl \
    -noshell \
    -eval 'halt(0).'; then

    ok "Erlang runtime"
  else
    warn "Erlang runtime failed"
    status=1
  fi

  run_as_dev codex --version \
    || status=1

  run_as_dev claude --version \
    || status=1

  # Never invoke Happy merely to discover its version. Validate its globally
  # installed npm package instead so doctor cannot initiate first-use pairing.
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

  run_as_dev elixir --version \
    || status=1

  run_as_dev mix phx.new --version \
    || status=1

  # Authentication state is informational and does not make a fresh,
  # not-yet-onboarded installation fail.

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

  if run_as_dev \
    bash \
    -lc \
    '
      [[ ! -e "$HOME/.happy" ]] ||
      [[ "$(stat -c "%a" "$HOME/.happy")" == "700" ]]
    '; then

    ok "Happy data directory permissions"
  else
    warn "~/.happy should have mode 0700"
    status=1
  fi

  if run_as_dev \
    bash \
    -lc \
    '
      [[ ! -e "$HOME/.happy/access.key" ]] ||
      [[ "$(stat -c "%a" "$HOME/.happy/access.key")" == "600" ]]
    '; then

    ok "Happy access key permissions"
  else
    warn "~/.happy/access.key should have mode 0600"
    status=1
  fi

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

  # Explicitly detect the unsafe SSH policy used by older versions.
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

    rm -f "$installer"

    die "Failed to download installer from ${installer_url}"
  fi

  chmod 0755 "$installer"

  info "Re-running installer"

  DEVBOX_REPO_URL="$repo_url" \
    bash "$installer"

  rm -f "$installer"

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

Native backends remain available as:

  claude
  codex

Configuring dev SSH does NOT disable or alter administrative/root SSH access.

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
MANAGER

chmod \
  0755 \
  /usr/local/bin/devbox

cat <<EOF >/etc/sudoers.d/90-devbox
${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/devbox ssh setup
${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/devbox ssh disable
EOF

chmod \
  0440 \
  /etc/sudoers.d/90-devbox

visudo \
  -cf \
  /etc/sudoers.d/90-devbox

msg_ok "Installed DevBox Manager"

msg_info "Configuring dev-only SSH policy"

readonly SSH_CONFIG="/etc/ssh/sshd_config.d/00-devbox.conf"
readonly SSH_MANAGED_KEY="${DEV_HOME}/.ssh/authorized_keys.devbox"
readonly SSH_STANDARD_KEY="${DEV_HOME}/.ssh/authorized_keys"
readonly SSH_DISABLED_MARKER="${DEV_HOME}/.config/devbox/ssh-disabled"

write_outer_dev_ssh_policy_enabled() {
  cat <<'EOF' >"$SSH_CONFIG"
# Managed by DevBox.
# This file intentionally applies only to user "dev".
# Administrative/root SSH configuration is not modified.

Match User dev
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys.devbox

Match all
EOF

  chmod 0644 "$SSH_CONFIG"
}

write_outer_dev_ssh_policy_disabled() {
  cat <<'EOF' >"$SSH_CONFIG"
# Managed by DevBox.
# Disable SSH login for user "dev" only.
# Administrative/root SSH configuration is not modified.

DenyUsers dev
EOF

  chmod 0644 "$SSH_CONFIG"
}

install \
  -d \
  -m 0755 \
  /etc/ssh/sshd_config.d

if [[ -n "${SSH_AUTHORIZED_KEY:-}" ]]; then
  key_file_tmp="$(mktemp)"

  chmod 0600 "$key_file_tmp"

  printf '%s\n' \
    "$SSH_AUTHORIZED_KEY" \
    >"$key_file_tmp"

  if ! ssh-keygen \
    -l \
    -f "$key_file_tmp" \
    >/dev/null 2>&1; then

    rm -f "$key_file_tmp"

    msg_error "SSH_AUTHORIZED_KEY is not a valid SSH public key."
    exit 1
  fi

  rm -f "$key_file_tmp"

  printf '%s\n' \
    "$SSH_AUTHORIZED_KEY" \
    >"$SSH_MANAGED_KEY"

  chown \
    "$DEV_USER:$DEV_USER" \
    "$SSH_MANAGED_KEY"

  chmod \
    0600 \
    "$SSH_MANAGED_KEY"

  rm \
    -f \
    "$SSH_DISABLED_MARKER"

  write_outer_dev_ssh_policy_enabled

elif [[ -e "$SSH_DISABLED_MARKER" ]]; then
  write_outer_dev_ssh_policy_disabled

elif [[ -s "$SSH_MANAGED_KEY" ||
        -s "$SSH_STANDARD_KEY" ]]; then
  write_outer_dev_ssh_policy_enabled

else
  # Fresh DevBox: deny SSH login for dev until explicitly configured.
  # This restriction applies only to dev and does not affect root/admin SSH.
  write_outer_dev_ssh_policy_disabled
fi

install -d -m 0755 /run/sshd
/usr/sbin/sshd -t

if systemctl is-active \
  --quiet \
  ssh.service; then

  # Reload preserves existing SSH sessions.
  systemctl reload ssh.service
fi

msg_ok "Configured dev-only SSH policy"
msg_ok "Existing administrative/root SSH policy was not restricted"

msg_info "Enabling Security Updates"

cat <<'EOF' >/etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable \
  --now \
  apt-daily.timer \
  apt-daily-upgrade.timer

msg_ok "Enabled Security Updates"

msg_info "Validating Installation"

node --version
npm --version

run_as_dev codex --version
run_as_dev claude --version

# Do not execute Happy during unattended installation/validation. Current
# Happy behaviour can enter normal startup/pairing after invocation.
run_as_dev npm list \
  --global \
  --depth=0 \
  happy

run_as_dev erl \
  -noshell \
  -eval 'halt(0).'

run_as_dev elixir \
  --version

run_as_dev mix phx.new \
  --version

systemctl is-active \
  --quiet \
  postgresql.service

run_as_dev psql \
  --host 127.0.0.1 \
  --username "$PG_DB_USER" \
  --dbname "$PG_DB_NAME" \
  --no-password \
  --command "SELECT 1;" \
  >/dev/null

/usr/local/bin/devbox doctor

msg_ok "Validated Installation"

msg_info "Cleaning Up"

apt-get \
  -y \
  autoremove \
  >>"$LOG_FILE" 2>&1 \
  || true

apt-get clean \
  >>"$LOG_FILE" 2>&1 \
  || true

rm \
  -f \
  "$LOG_FILE"

msg_ok "Cleaned Up"
msg_ok "Completed Successfully!"

echo
echo -e "${GN}DevBox setup has been successfully initialized!${CL}"
echo
echo -e "${YW}Enter the container and run:${CL}"
echo
echo "  sudo -iu dev"
echo
echo "The first interactive dev shell starts:"
echo
echo "  devbox onboard"
echo
echo -e "${YW}After onboarding, use Happy as the primary agent entry point:${CL}"
echo
echo "  happy"
echo "  happy codex"
echo
