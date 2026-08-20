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

# Read and shown before anything else runs (even the root/OS checks below),
# so a failure report from the very first line always names the exact
# installer version that produced it. The rest of the version manifest
# (Node.js, Erlang, agent CLIs, ...) is defined further down, where it's
# actually used.
readonly DEVBOX_VERSION="${DEVBOX_VERSION:-1.3.1}"

msg_info "DevBox installer v${DEVBOX_VERSION}"

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
    ubuntu-24.04 | ubuntu-22.04)
      msg_ok "Supported OS: Ubuntu ${os_version}"
      ;;
    *)
      msg_error "Unsupported OS: ${os_id:-unknown} ${os_version:-unknown}"
      # P2.2: 20.04 was previously accepted here, but no OTP 29.0.5
      # artifact exists for it (see DEVBOX_CHECKSUMS below) - the default
      # profile always failed on it. Dropped rather than pretending it
      # works; the recommended path per #18-P2.2 (adding a real 20.04
      # OTP artifact + checksum + E2E coverage) can restore it later.
      msg_error "Ubuntu 24.04 LTS is recommended; 22.04 is also supported."
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

# Root-owned DevBox state (active/previous version, installed features,
# install metadata) - readable by dev (devbox doctor runs without root),
# writable only by root. User-specific state stays under
# ${DEV_HOME}/.config/devbox (onboarding marker, OpenRouter config, etc.).
readonly ROOT_STATE_DIR="/var/lib/devbox"

# Central version manifest (mirrors devbox/versions.env; see header
# comment). DEVBOX_VERSION itself is defined and shown at the very top of
# this file, before the root/OS checks.
NODE_VERSION="${NODE_VERSION:-24}"
readonly NODE_VERSION
ERLANG_VERSION="${ERLANG_VERSION:-29.0.5}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.20.3}"
PHOENIX_VERSION="${PHOENIX_VERSION:-1.8.9}"
CODEX_VERSION="${CODEX_VERSION:-0.147.0}"
CLAUDE_VERSION="${CLAUDE_VERSION:-2.1.233}"
HAPPY_VERSION="${HAPPY_VERSION:-1.2.0}"
KISUKE_VERSION="${KISUKE_VERSION:-1.2.20}"

# Single source of truth for which remote/session providers exist. Each name
# here must have a devbox/features/<name>.sh module that defines the four
# provider hooks install.sh dispatches to below: remote_install_<name>,
# remote_bashrc_<name>, remote_validate_<name>, remote_banner_<name> (see
# devbox/README.md, "Neuen Remote-Provider hinzufügen"). "none" is always a
# valid DEVBOX_REMOTE value but deliberately not listed here - it has no
# module and no hooks to call.
readonly DEVBOX_REMOTE_PROVIDERS="happy kisuke"

DEVBOX_REPO_URL="${DEVBOX_REPO_URL:-https://raw.githubusercontent.com/c4kingpin/Scripts}"
DEVBOX_GITHUB_REPO="${DEVBOX_GITHUB_REPO:-c4kingpin/Scripts}"

# Branch/ref that sibling files (e.g. bin/devbox.sh) are fetched from during
# this install, so install.sh and the installed manager always come from the
# same commit. Defaults to the same branch `devbox update` uses.
DEVBOX_REF="${DEVBOX_REF:-master}"

# P1.3: DEVBOX_REF is a branch/tag name, resolved by GitHub's CDN
# independently on every raw.githubusercontent.com fetch below - if the
# branch moves mid-install, different modules could come from different
# commits. Resolve it once to the commit it names right now, then fetch
# every module from that fixed commit instead. No jq dependency: base.sh
# (which installs it) hasn't been fetched yet at this point.
resolve_devbox_ref_to_commit() {
  local ref="$1"
  local response sha

  response="$(
    curl \
      --proto '=https' \
      --tlsv1.2 \
      --connect-timeout 15 \
      --max-time 15 \
      --fail \
      --silent \
      --show-error \
      --header "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${DEVBOX_GITHUB_REPO}/commits/${ref}" \
      2>/dev/null
  )" || return 1

  sha="$(
    printf '%s' "$response" \
      | grep -o '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]\{40\}"' \
      | head -n1 \
      | grep -o '[0-9a-f]\{40\}'
  )"

  [[ -n "$sha" ]] || return 1

  printf '%s' "$sha"
}

devbox_resolved_commit=""

if devbox_resolved_commit="$(resolve_devbox_ref_to_commit "$DEVBOX_REF")"; then
  msg_ok "Pinned installer modules to commit ${devbox_resolved_commit}"
  DEVBOX_REF="$devbox_resolved_commit"
else
  devbox_resolved_commit=""
  msg_info "Could not resolve '${DEVBOX_REF}' to a commit; module downloads use the ref directly"
fi

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

devbox_modules=(
  lib/common.sh
  lib/user.sh
  features/base.sh
  features/node.sh
  features/postgres.sh
  features/redis.sh
  features/agents.sh
)

# Every registered remote provider is loaded as its own module - adding one
# to DEVBOX_REMOTE_PROVIDERS above is enough to have it fetched here, no
# further change needed in this list.
for devbox_remote_provider in $DEVBOX_REMOTE_PROVIDERS; do
  devbox_modules+=("features/${devbox_remote_provider}.sh")
done

devbox_modules+=(
  features/agent-notify.sh
  features/tooling.sh
  features/elixir.sh
)

for devbox_module in "${devbox_modules[@]}"; do
  fetch_devbox_module "$devbox_module" "$devbox_module_tmp"
  # shellcheck disable=SC1090
  source "$devbox_module_tmp"
done

rm -f "$devbox_module_tmp"

msg_ok "Loaded DevBox modules"

# Feature selection: base/agents/node/tooling are the DevBox core (an
# agent runtime environment without them isn't a DevBox) and always run.
# elixir and postgres are the heavy, project-specific runtimes a box may not
# need; redis (#10 P3) is a fully optional extra never on by default in
# either built-in profile - opt in explicitly via DEVBOX_FEATURES.
DEVBOX_ALL_OPTIONAL_FEATURES="elixir postgres redis"

# Only prompt when the caller left both knobs untouched - a genuinely fresh
# interactive install. Any explicit DEVBOX_PROFILE/DEVBOX_FEATURES (manual
# override, or update_devbox() re-running this script with the box's
# persisted selection) is respected as-is and never second-guessed with a
# prompt.
select_features() {
  if [[ -n "${DEVBOX_PROFILE+set}" || -n "${DEVBOX_FEATURES+set}" ]]; then
    return
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    return
  fi

  cat <<'EOF'

Which optional runtimes should this DevBox install?

  1) Default - Elixir/Erlang/Phoenix + PostgreSQL (recommended)
  2) Minimal - core only (Node.js, Codex CLI, Claude CLI)
  3) Custom  - choose each optional runtime individually

EOF

  local choice=""

  read -r \
    -p "Choice [1]: " \
    choice

  case "${choice:-1}" in
    2) DEVBOX_PROFILE="minimal" ;;
    3)
      local reply=""
      DEVBOX_PROFILE="minimal"
      DEVBOX_FEATURES=""

      read -r -p "Install Elixir/Erlang/Phoenix? [Y/n] " reply
      [[ -z "$reply" || "${reply,,}" =~ ^(y|yes)$ ]] &&
        DEVBOX_FEATURES="${DEVBOX_FEATURES:+$DEVBOX_FEATURES,}elixir"

      read -r -p "Install PostgreSQL? [Y/n] " reply
      [[ -z "$reply" || "${reply,,}" =~ ^(y|yes)$ ]] &&
        DEVBOX_FEATURES="${DEVBOX_FEATURES:+$DEVBOX_FEATURES,}postgres"

      read -r -p "Install Redis? [y/N] " reply
      [[ "${reply,,}" =~ ^(y|yes)$ ]] &&
        DEVBOX_FEATURES="${DEVBOX_FEATURES:+$DEVBOX_FEATURES,}redis"
      ;;
    *) DEVBOX_PROFILE="default" ;;
  esac
}

select_features

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

# #43: the remote-access layer is a swappable provider, not a DevBox-core
# requirement. Happy remains the default; Kisuke Connect is an alternative
# provider; "none" installs no remote layer at all (host console/SSH only).
# DEVBOX_REMOTE is unset (not "happy") on a re-install/update unless the
# caller passes it explicitly - update_devbox() in bin/devbox.sh always
# passes the box's persisted provider through, so a plain re-run of this
# script (no DEVBOX_REMOTE set) only happens on a genuinely fresh install,
# where "happy" is the correct default.
select_remote() {
  if [[ -n "${DEVBOX_REMOTE+set}" ]]; then
    return
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    return
  fi

  cat <<'EOF'

Which remote/session provider should this DevBox use?

  1) Happy  - happy / happy claude / happy codex remote session layer (recommended)
  2) Kisuke - Kisuke Connect (kisuke.dev), phone/tablet terminal+editor+chat
  3) None   - host console/SSH only, no remote provider

EOF

  local choice=""

  read -r \
    -p "Choice [1]: " \
    choice

  case "${choice:-1}" in
    2) DEVBOX_REMOTE="kisuke" ;;
    3) DEVBOX_REMOTE="none" ;;
    *) DEVBOX_REMOTE="happy" ;;
  esac
}

select_remote

DEVBOX_REMOTE="${DEVBOX_REMOTE:-happy}"

if [[ "$DEVBOX_REMOTE" != "none" &&
      " $DEVBOX_REMOTE_PROVIDERS " != *" $DEVBOX_REMOTE "* ]]; then

  msg_error "Invalid DEVBOX_REMOTE: ${DEVBOX_REMOTE} (expected none or one of: ${DEVBOX_REMOTE_PROVIDERS})"
  exit 1
fi

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

# Each provider module (features/<name>.sh) defines remote_install_<name>;
# see the DEVBOX_REMOTE_PROVIDERS comment above and devbox/README.md, "Neuen
# Remote-Provider hinzufügen".
if [[ "$DEVBOX_REMOTE" != "none" ]]; then
  "remote_install_${DEVBOX_REMOTE}"
fi

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

if feature_enabled redis; then
  install_redis_package
  enable_redis_service
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

# `sudo -iu dev` (the documented way to enter this box) simulates a login
# shell but does not register a systemd-logind session, so it never sets
# XDG_RUNTIME_DIR - even though a lingering `dev` user session (enabled for
# Kisuke Connect, see features/kisuke.sh) is genuinely running and has a
# real bus socket at /run/user/<uid>/bus. Without this, every
# `systemctl --user` call (including Kisuke's own) fails with "Failed to
# connect to bus: No medium found" despite the session being fine. This
# file is rewritten on every install/update, unlike the marker-guarded
# ~/.bashrc blocks, so it also reaches boxes that installed before this
# fix once they update.
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
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
  `~/.kisuke`, `~/.codex/auth.json`, `~/.claude/.credentials.json`, or
  DevBox secret files unless the user explicitly requests authentication
  troubleshooting.
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
notify = ["${DEV_HOME}/.local/bin/devbox-codex-limit-detect"]
EOF

  if [[ -n "$codex_network_access" ]]; then
    cat <<EOF >>"${DEV_HOME}/.codex/config.toml"

[sandbox_workspace_write]
network_access = ${codex_network_access}
EOF
  fi
else
  msg_info "Preserving existing ~/.codex/config.toml"

  if ! grep \
    -Fq \
    'devbox-codex-limit-detect' \
    "${DEV_HOME}/.codex/config.toml"; then

    msg_info "Add notify = [\"${DEV_HOME}/.local/bin/devbox-codex-limit-detect\"] to ~/.codex/config.toml for Codex limit notifications"
  fi
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
      "Read(~/.kisuke/**)",
      "Read(~/.codex/auth.json)",
      "Read(~/.claude/.credentials.json)",
      "Read(~/.config/devbox/openrouter.env)"
    ]
  },
  "hooks": {
    "StopFailure": [
      {
        "matcher": "rate_limit|billing_error",
        "hooks": [
          {
            "type": "command",
            "command": "${DEV_HOME}/.local/bin/devbox-claude-limit-detect"
          }
        ]
      }
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

    jq \
      --arg command "${DEV_HOME}/.local/bin/devbox-claude-limit-detect" \
      '
      .permissions = (.permissions // {}) |
      .permissions.deny = (
        (
          (.permissions.deny // [])
          + ["Read(~/.happy/access.key)", "Read(~/.kisuke/**)"]
        )
        | unique
      ) |
      .hooks = (.hooks // {}) |
      .hooks.StopFailure = (
        (.hooks.StopFailure // []) as $existing |
        if ($existing | any(.hooks[]?.command? == $command))
        then $existing
        else $existing + [{
          "matcher": "rate_limit|billing_error",
          "hooks": [{"type": "command", "command": $command}]
        }]
        end
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
    msg_error "Happy credential deny rule and limit-notify hook could not be added."
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

# Each provider module (features/<name>.sh) defines remote_bashrc_<name>,
# which appends its own dev-shell fallback snippet to ~/.bashrc.
if [[ "$DEVBOX_REMOTE" != "none" ]]; then
  "remote_bashrc_${DEVBOX_REMOTE}"
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
  "${DEV_HOME}/.happy" \
  "${DEV_HOME}/.kisuke"

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

msg_info "Recording DevBox state"

install \
  -d \
  -m 0755 \
  "$ROOT_STATE_DIR"

# P1.2/P1.3 briefly recorded this under the user-state directory, before
# ROOT_STATE_DIR existed. Migrate it once so an in-place update doesn't
# strand the selection a prior run already made.
if [[ -f "${DEV_HOME}/.config/devbox/features" &&
      ! -f "${ROOT_STATE_DIR}/installed-features" ]]; then

  mv \
    "${DEV_HOME}/.config/devbox/features" \
    "${ROOT_STATE_DIR}/installed-features"
fi

printf '%s\n' "$DEVBOX_VERSION" >"${ROOT_STATE_DIR}/version"
printf '%s\n' "$devbox_selected_features" >"${ROOT_STATE_DIR}/installed-features"

# #43: persists which remote provider this box was configured with, so
# devbox status/doctor can report it and so a later `devbox update`
# (which threads the persisted value back in as DEVBOX_REMOTE) doesn't
# silently fall back to the "happy" default and reconfigure a box that
# was deliberately installed with DEVBOX_REMOTE=none.
printf '%s\n' "$DEVBOX_REMOTE" >"${ROOT_STATE_DIR}/remote-provider"

# P1.1: seeds active-ref for a fresh install, so the first `devbox update`
# has something real to record as "previous" before overwriting it.
# devbox update itself always overwrites this afterwards with the exact
# mode it already knows (--to/--branch), which is more accurate than this
# guess - DEVBOX_REF alone doesn't say whether it's a release tag or a
# branch name. Note DEVBOX_REF may already be a resolved commit SHA at
# this point (P1.3), which the branch heuristic below correctly falls
# into "branch" (a SHA is not a SemVer tag) - the more precise of the two
# anyway, since it pins the exact commit rather than a moving branch tip.
if [[ "$DEVBOX_REF" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  devbox_active_mode="release"
else
  devbox_active_mode="branch"
fi

printf '%s:%s\n' "$devbox_active_mode" "$DEVBOX_REF" >"${ROOT_STATE_DIR}/active-ref"

if [[ -n "$devbox_resolved_commit" ]]; then
  printf '%s\n' "$devbox_resolved_commit" >"${ROOT_STATE_DIR}/commit"
fi

install_os_version="$(
  . /etc/os-release
  printf '%s' "${VERSION_ID}"
)"
install_arch="$(dpkg --print-architecture)"
install_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat <<EOF >"${ROOT_STATE_DIR}/install-state.json"
{
  "version": "${DEVBOX_VERSION}",
  "commit": "${devbox_resolved_commit}",
  "profile": "${DEVBOX_PROFILE}",
  "features": "${devbox_selected_features}",
  "remote": "${DEVBOX_REMOTE}",
  "os": "${install_os_version}",
  "arch": "${install_arch}",
  "installed_at": "${install_timestamp}"
}
EOF

chmod \
  0644 \
  "${ROOT_STATE_DIR}/version" \
  "${ROOT_STATE_DIR}/installed-features" \
  "${ROOT_STATE_DIR}/install-state.json" \
  "${ROOT_STATE_DIR}/active-ref" \
  "${ROOT_STATE_DIR}/remote-provider"

if [[ -f "${ROOT_STATE_DIR}/commit" ]]; then
  chmod 0644 "${ROOT_STATE_DIR}/commit"
fi

msg_ok "Recorded DevBox state"

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

# Each provider module (features/<name>.sh) defines remote_validate_<name>,
# an unattended (no Happy/Kisuke CLI execution) post-install check.
if [[ "$DEVBOX_REMOTE" != "none" ]]; then
  "remote_validate_${DEVBOX_REMOTE}"
fi

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

if feature_enabled redis; then
  systemctl is-active \
    --quiet \
    redis-server.service

  redis-cli ping \
    >/dev/null
fi

# Validate both the installer and generated manager before success.
# $0 is not a path to this script when run via `curl | bash` (it's
# typically just "bash"), so only self-check when $0 is a real file.
if [[ -f "$0" ]]; then
  bash \
    -n \
    "$0"
fi

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
if [[ "$DEVBOX_REMOTE" != "none" ]]; then
  # Each provider module (features/<name>.sh) defines remote_banner_<name>,
  # the final "how to use it" lines for that provider.
  "remote_banner_${DEVBOX_REMOTE}"
else
  echo -e "${YW}No remote provider configured (DEVBOX_REMOTE=none). Use Codex/Claude${CL}"
  echo -e "${YW}directly, or reach this box over SSH:${CL}"
  echo
  echo "  codex"
  echo "  claude"
fi
