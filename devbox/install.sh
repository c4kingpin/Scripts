#!/usr/bin/env bash
# Copyright (c) 2021-2026 c4kingpin
# Author: Jörn Siedentopf (c4kingpin)
# License: MIT
# Sources:
#   https://github.com/openai/codex
#   https://github.com/anthropics/claude-code
#   https://github.com/slopus/happy
#
# DevBox - standalone Ubuntu LTS LXC installer
#
# Runtime model:
#   root      -> OS/packages/system services/toolchain administration
#   postgres  -> PostgreSQL service
#   dev       -> Happy, Claude Code, Codex, Git/GitHub, workspaces, credentials
#             -> may request OS package installs only via the controlled
#                `sudo devbox packages install <package...>` command
#                (see /etc/sudoers.d/90-devbox); dev has no generic
#                passwordless apt/apt-get/dpkg access.
#
# Managed tool versions are centrally defined in devbox/versions.env; the
# defaults embedded below must stay in sync with that file (enforced by
# devbox/tests/test-devbox.sh) so the installer keeps working as a single
# curl-pipeable file.
#
# Happy is the primary session/remote layer:
#   happy
#   happy claude
#   happy codex
#
# Native Claude and Codex remain installed as backends:
#   claude
#   codex
#
# Existing administrative/root SSH access is deliberately not restricted.
# DevBox SSH policy applies only to the dev account.

set -Eeuo pipefail
umask 022

RD=$'\033[01;31m'
GN=$'\033[1;92m'
YW=$'\033[33m'
CL=$'\033[m'

msg_info() { printf '%b\n' "${YW}➜ $*${CL}"; }
msg_ok() { printf '%b\n' "${GN}✓ $*${CL}"; }
msg_error() { printf '%b\n' "${RD}✗ $*${CL}" >&2; }

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
    os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    os_version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  fi

  case "${os_id}-${os_version}" in
    ubuntu-24.04 | ubuntu-22.04 | ubuntu-20.04)
      msg_ok "Supported OS: Ubuntu ${os_version}"
      ;;
    *)
      msg_error "Unsupported OS: ${os_id:-unknown} ${os_version:-unknown}"
      msg_error "Ubuntu 24.04 LTS is recommended; 22.04 and 20.04 are also supported."
      exit 1
      ;;
  esac
}

ensure_sshd_runtime() {
  install -d -m 0755 /run/sshd
}

repair_legacy_ssh_policy() {
  local ssh_config="/etc/ssh/sshd_config.d/00-devbox.conf"

  [[ -f "$ssh_config" ]] || return 0

  if grep -Eq '^(PermitRootLogin no|AllowUsers dev|AuthenticationMethods publickey)$' "$ssh_config"; then
    msg_info "Removing legacy global DevBox SSH restrictions"
    rm -f "$ssh_config"

    if [[ -x /usr/sbin/sshd ]]; then
      ensure_sshd_runtime
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

fetch_devbox_module() {
  local module_path="$1"
  local destination="$2"
  local url="${DEVBOX_REPO_URL%/}/${DEVBOX_REF}/devbox/${module_path}"

  if ! curl_with_retry "$url" "$destination"; then
    msg_error "Failed to download ${module_path} from ${url}"
    exit 1
  fi
}

require_root
require_supported_os
repair_legacy_ssh_policy
network_check
update_os

readonly DEV_USER="dev"
readonly DEV_HOME="/home/${DEV_USER}"

# Central version manifest (mirrors devbox/versions.env; see header comment).
readonly DEVBOX_VERSION="${DEVBOX_VERSION:-1.0.0}"
NODE_VERSION="${NODE_VERSION:-24}"
readonly NODE_VERSION
ERLANG_VERSION="${ERLANG_VERSION:-29.0.5}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.20.3}"
PHOENIX_VERSION="${PHOENIX_VERSION:-1.8.9}"
CODEX_VERSION="${CODEX_VERSION:-0.147.0}"
CLAUDE_VERSION="${CLAUDE_VERSION:-2.1.233}"
HAPPY_VERSION="${HAPPY_VERSION:-1.2.0}"

DEVBOX_REPO_URL="${DEVBOX_REPO_URL:-https://raw.githubusercontent.com/c4kingpin/Scripts}"

# Branch/ref that sibling files (e.g. bin/devbox.sh) are fetched from during
# this install, so install.sh and the installed manager always come from the
# same commit. Real commit/tag pinning arrives with release-based updates
# (P1.3); until then this defaults to the same branch `devbox update` uses.
DEVBOX_REF="${DEVBOX_REF:-master}"

# Known-good SHA256 checksums for versioned binary artifacts (mirrors
# devbox/checksums.env). Keyed as "<artifact>:<version-or-otp-major>[:<os>:<arch>]".
declare -A DEVBOX_CHECKSUMS=(
  ["otp:29.0.5:ubuntu-24.04:amd64"]="1ecf8a20104afa053e6701e36ec1485cbce1a2fa4aef962d5e73f9eb5c6e9fc0"
  ["otp:29.0.5:ubuntu-22.04:amd64"]="da6f05c7b292f7726cdee6794e7a48542cc47384c3fdaeeb737df8aa5de24acf"
  ["otp:29.0.5:ubuntu-24.04:arm64"]="7ab17628fca446dc02d40ecb0afe6c18e72437e09fca5c90d208c66db4206ae0"
  ["otp:29.0.5:ubuntu-22.04:arm64"]="22bb49411e0a6dbb1829a32a2d31cc1cecc994e0c828d97845696ded66cd9c09"
  ["elixir:1.20.3:29"]="51f799b78374d569a5df659bdedeb0dd9ef8251230bcdaef00c533019086e625"
)
readonly DEVBOX_CHECKSUMS

verify_checksum() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual

  actual="$(sha256sum "$file" | awk '{print $1}')"

  if [[ -z "$expected" ]]; then
    rm -f "$file"
    msg_error "No known checksum for ${label}; refusing to install it."
    exit 1
  fi

  if [[ "$actual" != "$expected" ]]; then
    rm -f "$file"
    msg_error "Checksum mismatch for ${label} (expected ${expected}, got ${actual})."
    exit 1
  fi

  msg_ok "Verified checksum for ${label}"
}

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

  1) Controlled   - read-only; approve edits and commands
  2) Balanced     - edit workspace; approve external access (recommended)
  3) Autonomous   - workspace and network without approval prompts
  4) Full access  - no agent sandbox or prompts (LXC boundary only)

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
  locales \
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

ensure_sshd_runtime

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

  if ! run_as_dev test \
    -w "$developer_dir"; then

    msg_error "Developer directory is not writable: ${developer_dir}"
    exit 1
  fi
done

msg_ok "Created Developer User"

msg_info "Installing Codex CLI ${CODEX_VERSION}"

silent npm install \
  --global \
  "@openai/codex@${CODEX_VERSION}"

msg_ok "Installed Codex CLI ${CODEX_VERSION}"

msg_info "Installing Claude Code ${CLAUDE_VERSION}"

silent npm install \
  --global \
  "@anthropic-ai/claude-code@${CLAUDE_VERSION}"

msg_ok "Installed Claude Code ${CLAUDE_VERSION}"

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

msg_info "Installing mise"

mise_installer="/tmp/devbox-mise-install.sh"

curl_with_retry \
  "https://mise.run" \
  "$mise_installer"

chmod \
  0755 \
  "$mise_installer"

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

verify_checksum \
  "$otp_tarball" \
  "${DEVBOX_CHECKSUMS["otp:${ERLANG_VERSION}:${otp_os}:${otp_arch}"]:-}" \
  "Erlang/OTP ${ERLANG_VERSION} (${otp_os}, ${otp_arch})"

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

verify_checksum \
  "$elixir_zip" \
  "${DEVBOX_CHECKSUMS["elixir:${ELIXIR_VERSION}:${ERLANG_OTP_MAJOR}"]:-}" \
  "Elixir ${ELIXIR_VERSION} (OTP ${ERLANG_OTP_MAJOR})"

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
        (
          (.permissions.deny // [])
          + ["Read(~/.happy/access.key)"]
        )
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
alias hclaude='happy claude'
alias hcodex='happy codex'

# Start Happy daemon only after Happy has already been paired.
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

fetch_devbox_module "bin/devbox.sh" "/usr/local/bin/devbox"

chmod \
  0755 \
  /usr/local/bin/devbox

cat <<EOF >/etc/sudoers.d/90-devbox
${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/devbox ssh setup
${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/devbox ssh disable
${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/devbox packages install *
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
# Applies only to user "dev". Root/admin SSH policy is untouched.

Match User dev
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys.devbox

Match all
EOF

  chmod \
    0644 \
    "$SSH_CONFIG"
}

write_outer_dev_ssh_policy_disabled() {
  cat <<'EOF' >"$SSH_CONFIG"
# Managed by DevBox.
# Disable SSH login for user "dev" only.
# Root/admin SSH policy is untouched.

DenyUsers dev
EOF

  chmod \
    0644 \
    "$SSH_CONFIG"
}

install \
  -d \
  -m 0755 \
  /etc/ssh/sshd_config.d

ensure_sshd_runtime

ssh_policy_changed=0

if [[ -n "${SSH_AUTHORIZED_KEY:-}" ]]; then
  key_file_tmp="$(mktemp)"

  chmod \
    0600 \
    "$key_file_tmp"

  printf '%s\n' \
    "$SSH_AUTHORIZED_KEY" \
    >"$key_file_tmp"

  if ! ssh-keygen \
    -l \
    -f "$key_file_tmp" \
    >/dev/null 2>&1; then

    rm \
      -f \
      "$key_file_tmp"

    msg_error "SSH_AUTHORIZED_KEY is not a valid SSH public key."
    exit 1
  fi

  rm \
    -f \
    "$key_file_tmp"

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

  ssh_policy_changed=1

elif [[ -e "$SSH_DISABLED_MARKER" ]]; then
  write_outer_dev_ssh_policy_disabled
  ssh_policy_changed=1

elif [[ -s "$SSH_MANAGED_KEY" ||
        -s "$SSH_STANDARD_KEY" ]]; then

  write_outer_dev_ssh_policy_enabled
  ssh_policy_changed=1

elif [[ -f "$SSH_CONFIG" ]]; then

  if grep \
    -Fq \
    '# Managed by DevBox.' \
    "$SSH_CONFIG" \
    && ! grep \
      -Eq \
      '^(PermitRootLogin no|AllowUsers dev)$' \
      "$SSH_CONFIG"; then

    :
  else
    rm \
      -f \
      "$SSH_CONFIG"

    ssh_policy_changed=1
  fi
fi

ensure_sshd_runtime

/usr/sbin/sshd -t

if [[ "$ssh_policy_changed" -eq 1 ]] &&
  systemctl is-active \
    --quiet \
    ssh.service; then

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

run_as_dev codex \
  --version

run_as_dev claude \
  --version

# Do not execute Happy during unattended validation.
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

# Validate both the installer and generated manager before success.
bash \
  -n \
  "$0"

bash \
  -n \
  /usr/local/bin/devbox

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
