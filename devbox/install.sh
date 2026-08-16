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
# shellcheck disable=SC2034 # read by features/elixir.sh after it's sourced
readonly DEVBOX_CHECKSUMS

msg_info "Loading DevBox modules"

devbox_module_tmp="$(mktemp)"

for devbox_module in \
  lib/common.sh \
  lib/user.sh \
  features/base.sh \
  features/node.sh \
  features/postgres.sh \
  features/agents.sh \
  features/happy.sh \
  features/tooling.sh \
  features/elixir.sh; do

  fetch_devbox_module "$devbox_module" "$devbox_module_tmp"
  # shellcheck disable=SC1090
  source "$devbox_module_tmp"
done

rm -f "$devbox_module_tmp"

msg_ok "Loaded DevBox modules"

# Feature selection: base/agents/happy/node/tooling are the DevBox core (an
# agent runtime environment without them isn't a DevBox) and always run.
# elixir and postgres are the heavy, project-specific runtimes a box may not
# need, so they're the only toggleable features.
DEVBOX_ALL_OPTIONAL_FEATURES="elixir postgres"

DEVBOX_PROFILE="${DEVBOX_PROFILE:-default}"

case "$DEVBOX_PROFILE" in
  default) devbox_profile_features="elixir postgres" ;;
  minimal) devbox_profile_features="" ;;
  *)
    msg_error "Invalid DEVBOX_PROFILE: ${DEVBOX_PROFILE} (expected default or minimal)"
    exit 1
    ;;
esac

# An explicitly empty DEVBOX_FEATURES ("no optional features") must be
# honored, so this checks whether the variable is set at all rather than
# falling back on emptiness.
if [[ -n "${DEVBOX_FEATURES+set}" ]]; then
  devbox_selected_features="${DEVBOX_FEATURES//,/ }"
else
  devbox_selected_features="$devbox_profile_features"
fi

for devbox_feature in $devbox_selected_features; do
  [[ " $DEVBOX_ALL_OPTIONAL_FEATURES " == *" $devbox_feature "* ]] || {
    msg_error "Unknown DevBox feature: ${devbox_feature} (expected: ${DEVBOX_ALL_OPTIONAL_FEATURES})"
    exit 1
  }
done

feature_enabled() {
  [[ " $devbox_selected_features " == *" $1 "* ]]
}

msg_ok "DevBox profile: ${DEVBOX_PROFILE} (optional features: ${devbox_selected_features:-none})"

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

enable_ubuntu_universe
install_os_dependencies

ensure_sshd_runtime

install_nodejs

create_developer_user

install_codex_cli
install_claude_cli
install_happy

install_mise

if feature_enabled elixir; then
  install_erlang
  install_elixir_and_phoenix
fi

if feature_enabled postgres; then
  readonly PG_DB_NAME="devbox"
  readonly PG_DB_USER="dev"
  # shellcheck disable=SC2034 # read by configure_postgres_dev_access() in features/postgres.sh
  readonly PG_ENV_FILE="${DEV_HOME}/.config/devbox/postgres.env"

  install_postgres_package
  enable_postgresql_service
  configure_postgres_dev_access
fi

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

msg_info "Recording feature selection"

install \
  -d \
  -m 0755 \
  -o "$DEV_USER" \
  -g "$DEV_USER" \
  "${DEV_HOME}/.config/devbox"

printf '%s\n' "$devbox_selected_features" >"${DEV_HOME}/.config/devbox/features"

chown \
  "$DEV_USER:$DEV_USER" \
  "${DEV_HOME}/.config/devbox/features"

chmod \
  0644 \
  "${DEV_HOME}/.config/devbox/features"

msg_ok "Recorded feature selection"

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

if feature_enabled elixir; then
  run_as_dev erl \
    -noshell \
    -eval 'halt(0).'

  run_as_dev elixir \
    --version

  run_as_dev mix phx.new \
    --version
fi

if feature_enabled postgres; then
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
fi

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
