#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
TEST_TMP="$(mktemp -d /tmp/codex-devbox-tests.XXXXXX)"
readonly TEST_TMP
readonly MANAGER="${TEST_TMP}/codex-devbox"

PASSED=0
FAILED=0

cleanup() {
  if [[ "$TEST_TMP" == /tmp/codex-devbox-tests.* && -d "$TEST_TMP" ]]; then
    rm -rf "$TEST_TMP"
  fi
}
trap cleanup EXIT

run_test() {
  local name="$1"
  shift

  if "$@"; then
    printf 'ok - %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'not ok - %s\n' "$name"
    FAILED=$((FAILED + 1))
  fi
}

extract_manager() {
  awk '
    /^cat <<'\''MANAGER'\'' >\/usr\/local\/bin\/codex-devbox$/ {
      capture=1
      next
    }
    /^MANAGER$/ {
      capture=0
    }
    capture
  ' "$INSTALL_SCRIPT" >"$MANAGER"
  chmod 0755 "$MANAGER"
}

scripts_have_valid_syntax() {
  bash -n "$INSTALL_SCRIPT" "$MANAGER"
}

standalone_no_proxmox_framework() {
  [[ -f "$INSTALL_SCRIPT" ]] &&
    [[ ! -d "${REPO_ROOT}/ct" ]] &&
    [[ ! -d "${REPO_ROOT}/json" ]] &&
    [[ ! -d "${REPO_ROOT}/install" ]] &&
    ! grep -Eq \
      'FUNCTIONS_FILE_PATH|build_container\(\)|COMMUNITY_FRAMEWORK_URL|ProxmoxVED|whiptail|pct create|pveam|pvesm|pvesh get /cluster/nextid|create_container\(' \
      "$INSTALL_SCRIPT"
}

install_script_runs_standalone_preflight() {
  grep -Fq 'require_root() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'require_debian_like() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'network_check() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'update_os() {' "$INSTALL_SCRIPT" &&
    grep -Fxq 'require_root' "$INSTALL_SCRIPT" &&
    grep -Fxq 'require_debian_like' "$INSTALL_SCRIPT" &&
    grep -Fxq 'network_check' "$INSTALL_SCRIPT" &&
    grep -Fxq 'update_os' "$INSTALL_SCRIPT"
}

installer_curl_pipeable_from_master() {
  grep -Fq 'curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/install.sh | bash' \
    "$INSTALL_SCRIPT"
}

install_script_is_bare_metal() {
  ! grep -Eq 'setup_docker|docker (run|compose|pull)|podman' "$INSTALL_SCRIPT"
}

erlang_toolchain_supports_debian_13() {
  grep -Fq autoconf "$INSTALL_SCRIPT" &&
    grep -Fq libncurses-dev "$INSTALL_SCRIPT" &&
    grep -Fq libssl-dev "$INSTALL_SCRIPT" &&
    grep -Fq 'MISE_ERLANG_COMPILE=true' "$INSTALL_SCRIPT" &&
    grep -Fq 'KERL_CONFIGURE_OPTIONS="--without-javac --without-wx --without-odbc"' \
      "$INSTALL_SCRIPT"
}

elixir_is_pinned_to_the_erlang_otp_major() {
  # mise's core Elixir plugin ships one OTP-unpinned build from builds.hex.pm,
  # which crashes at boot against the from-source Erlang built above. Elixir
  # must come from its own OTP-major-tagged GitHub release instead.
  grep -Fq 'ERLANG_OTP_MAJOR="${ERLANG_VERSION%%.*}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'releases/download/v${ELIXIR_VERSION}/elixir-otp-${ERLANG_OTP_MAJOR}.zip' \
      "$INSTALL_SCRIPT" &&
    ! grep -Eq 'mise" use --global "elixir@|mise use --global "elixir@' "$INSTALL_SCRIPT" &&
    ! grep -Eq 'mise" exec -- (elixir|mix|iex)|mise exec -- (elixir|mix|iex)' \
      "$INSTALL_SCRIPT"
}

claude_cli_is_installed() {
  grep -Fq 'npm install --global @anthropic-ai/claude-code@latest' "$INSTALL_SCRIPT" &&
    grep -Fq 'npm install --global @openai/codex@latest' "$INSTALL_SCRIPT" &&
    grep -Fq 'claude' "$MANAGER" &&
    grep -Fxq 'claude --version' "$INSTALL_SCRIPT" &&
    grep -Fq 'run_as_dev claude --version' "$MANAGER"
}

doctor_checks_claude_alongside_codex() {
  python3 - "$MANAGER" <<'PY'
import pathlib
import re
import sys

manager = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"local commands=\((.*?)\)", manager, re.S)
assert match, "doctor() commands array not found"
commands = match.group(1).split()
assert "claude" in commands, commands
assert "codex" in commands, commands
PY
}

update_command_supports_branch_argument() {
  grep -Fq 'update_devbox() {' "$MANAGER" &&
    grep -Fq 'readonly DEFAULT_UPDATE_BRANCH="master"' "$MANAGER" &&
    grep -Fq 'local branch="${1:-$DEFAULT_UPDATE_BRANCH}"' "$MANAGER" &&
    grep -Fq 'local installer_url="${repo_url%/}/${branch}/install.sh"' "$MANAGER" &&
    grep -Fq 'update:*)' "$MANAGER" &&
    grep -Fq 'update_devbox "$subcommand"' "$MANAGER" &&
    grep -Fq 'update [branch]' "$MANAGER"
}

update_downloads_and_reruns_installer() {
  grep -Fq 'curl -fsSL --connect-timeout 15 --retry 5 --retry-connrefused' "$MANAGER" &&
    grep -Fq 'bash "$installer"' "$MANAGER" &&
    grep -Fq 'Failed to download installer from' "$MANAGER" &&
    grep -Fq 'DEFAULT_REPO_URL="https://raw.githubusercontent.com/c4kingpin/Scripts"' "$MANAGER"
}

update_branch_argument_is_honored() {
  local fake_repo="${TEST_TMP}/fake-repo"
  local output_file="${TEST_TMP}/update-output.log"
  local bin_dir="${TEST_TMP}/bin"
  local manager_functions="${TEST_TMP}/manager-functions.sh"

  mkdir -p "$fake_repo" "$bin_dir"
  cat <<'EOF' >"${fake_repo}/install.sh"
#!/usr/bin/env bash
echo "ran fake installer"
EOF
  chmod 0755 "${fake_repo}/install.sh"

  cat <<EOF >"${bin_dir}/curl"
#!/usr/bin/env bash
out=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "-o" ]]; then
    out="\$arg"
  fi
  prev="\$arg"
done
url="\${!#}"
case "\$url" in
*/feature-branch/install.sh)
  cp "${fake_repo}/install.sh" "\$out"
  ;;
*)
  exit 22
  ;;
esac
EOF
  chmod 0755 "${bin_dir}/curl"

  # Drop the trailing "main \"\$@\"" call so sourcing only defines functions.
  head -n -1 "$MANAGER" >"$manager_functions"

  (
    set -Eeuo pipefail
    PATH="${bin_dir}:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$manager_functions"
    # shellcheck disable=SC2317,SC2329 # invoked indirectly by update_devbox below
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # invoked indirectly by update_devbox below
    doctor() { :; }
    update_devbox feature-branch
  ) >"$output_file" 2>&1 || true

  grep -Fq "ran fake installer" "$output_file" &&
    grep -Fq "Downloading installer from branch 'feature-branch'" "$output_file"
}

developer_user_is_least_privilege() {
  grep -Fq 'useradd --create-home --user-group --shell /bin/bash' \
    "$INSTALL_SCRIPT" &&
    grep -Fq 'PermitRootLogin no' "$INSTALL_SCRIPT" &&
    grep -Fq 'PasswordAuthentication no' "$INSTALL_SCRIPT" &&
    grep -Fq 'AllowUsers ${DEV_USER}' "$INSTALL_SCRIPT" &&
    grep -Fq \
      '${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/codex-devbox ssh setup' \
      "$INSTALL_SCRIPT" &&
    ! grep -Eq 'NOPASSWD:[[:space:]]*ALL' "$INSTALL_SCRIPT"
}

developer_password_only_set_on_creation() {
  python3 - "$INSTALL_SCRIPT" <<'PY'
import pathlib
import re
import sys

install = pathlib.Path(sys.argv[1]).read_text()
match = re.search(
    r'if ! id "\$DEV_USER".*?\n(.*?)\nfi\n',
    install,
    re.S,
)
assert match, "user-creation guard block not found"
block = match.group(1)
assert "useradd" in block
assert "random_password" in block
assert "usermod --password" in block
PY
}

developer_home_parents_are_writable() {
  local config_line
  local state_line
  local mise_line
  local permissions_root="${TEST_TMP}/permissions"

  config_line="$(grep -nF '"${DEV_HOME}/.config"' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"
  state_line="$(grep -nF '"${DEV_HOME}/.config/codex-devbox"' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"
  mise_line="$(grep -nF 'MISE_INSTALL_PATH=' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"

  grep -Fq 'run_as_dev test -w "$developer_dir"' "$INSTALL_SCRIPT" &&
    grep -Fq 'Developer directory is not writable:' "$INSTALL_SCRIPT" ||
    return 1

  [[ -n "$config_line" && -n "$state_line" && -n "$mise_line" ]] &&
    ((config_line < state_line && state_line < mise_line)) &&
    grep -Fq '"${DEV_HOME}/.cache"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.local"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.local/bin"' "$INSTALL_SCRIPT" || return 1

  install -d -m 0500 "${permissions_root}/.config"
  if mkdir "${permissions_root}/.config/mise" 2>/dev/null; then
    return 1
  fi
  chmod 0700 "${permissions_root}/.config"
  mkdir "${permissions_root}/.config/mise"
}

rerunning_installer_is_idempotent() {
  grep -Fq 'if ! grep -Fq '\''# Codex Dev Box'\'' "${DEV_HOME}/.bashrc"' "$INSTALL_SCRIPT" &&
    grep -Fq 'if [[ ! -f "${DEV_HOME}/.codex/config.toml" ]]; then' "$INSTALL_SCRIPT" &&
    grep -Fq 'if [[ -f "${DEV_HOME}/.codex/config.toml" ]]; then' "$INSTALL_SCRIPT" &&
    grep -Fq 'elif [[ ! -s "${DEV_HOME}/.ssh/authorized_keys" ]]; then' "$INSTALL_SCRIPT" &&
    grep -Fq "SELECT 1 FROM pg_roles WHERE rolname = '\${PG_DB_USER}'" "$INSTALL_SCRIPT" &&
    grep -Fq "SELECT 1 FROM pg_database WHERE datname = '\${PG_DB_NAME}'" "$INSTALL_SCRIPT" &&
    grep -Fq "grep -q '^PGPASSWORD='" "$INSTALL_SCRIPT"
}

ssh_onboarding_distinguishes_key_directions() {
  grep -Fq 'A private client key must' "$INSTALL_SCRIPT" &&
    grep -Fq 'SSH_AUTHORIZED_KEY' "$INSTALL_SCRIPT" &&
    grep -Fq 'keys generate' "$MANAGER" &&
    grep -Fq 'ssh-keygen' "$MANAGER" &&
    grep -Fq 'keys upload-github' "$MANAGER"
}

unsupported_cli_remote_service_is_absent() {
  ! grep -Eq \
    'codex remote-control|codex-remote-control\.service|app-server-control\.sock' \
    "$INSTALL_SCRIPT"
}

remote_instructions_are_platform_agnostic() {
  local output

  output="$("$MANAGER" remote-info)"
  grep -Fq 'ChatGPT on iOS' <<<"$output" &&
    grep -Fq 'ChatGPT desktop app on macOS or Windows' <<<"$output" &&
    grep -Fq 'SSH connection' <<<"$output" &&
    grep -Fq 'pct enter <CTID>' <<<"$output" &&
    grep -Fq 'lxc exec' <<<"$output" &&
    grep -Fq 'incus exec' <<<"$output"
}

manager_exposes_expected_commands() {
  local output

  output="$("$MANAGER" --help)"
  grep -Fq 'onboard' <<<"$output" &&
    grep -Fq 'ssh setup' <<<"$output" &&
    grep -Fq 'auth login' <<<"$output" &&
    grep -Fq 'openrouter setup' <<<"$output" &&
    grep -Fq 'github setup' <<<"$output" &&
    grep -Fq 'keys generate' <<<"$output" &&
    grep -Fq 'remote-info' <<<"$output" &&
    grep -Fq 'doctor' <<<"$output" &&
    grep -Fq 'update [branch]' <<<"$output"
}

manager_rejects_unknown_commands() {
  local status=0

  "$MANAGER" does-not-exist >/dev/null 2>&1 || status=$?
  [[ "$status" -eq 2 ]]
}

no_hardcoded_default_credentials() {
  ! grep -Eq \
    'PASSWORD=(postgres|password|changeme)|password["'\'']?[[:space:]]*[:=][[:space:]]*["'\'']?(postgres|password|changeme)' \
    "$INSTALL_SCRIPT"
}

managed_secrets_have_restricted_permissions() {
  grep -Fq 'chmod 0600' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.pgpass"' "$INSTALL_SCRIPT" &&
    grep -Fq '"$PG_ENV_FILE"' "$INSTALL_SCRIPT" &&
    grep -Fq 'chmod 0600 "${DEV_HOME}/.codex/config.toml"' \
      "$INSTALL_SCRIPT" &&
    grep -Fq 'chmod 0600 "$OPENROUTER_ENV"' "$MANAGER"
}

codex_autonomy_is_selectable_and_persisted() {
  grep -Fq 'select_codex_autonomy() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'CODEX_AUTONOMY' "$INSTALL_SCRIPT" &&
    grep -Fq 'How autonomously may Codex work?' "$INSTALL_SCRIPT" &&
    grep -Fq 'approval_policy = "${codex_approval_policy}"' \
      "$INSTALL_SCRIPT" &&
    grep -Fq 'sandbox_mode = "${codex_sandbox_mode}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'network_access = ${codex_network_access}' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex_approval_policy="untrusted"' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex_approval_policy="on-request"' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex_approval_policy="never"' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex_sandbox_mode="read-only"' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex_sandbox_mode="workspace-write"' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex_sandbox_mode="danger-full-access"' "$INSTALL_SCRIPT"
}

openrouter_configuration_is_safe_and_supported() {
  grep -Fq 'openrouter_setup() {' "$MANAGER" &&
    grep -Fq 'read -r -s -p "OpenRouter API key: "' "$MANAGER" &&
    grep -Fq 'OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex-openrouter"' \
      "$MANAGER" &&
    grep -Fq 'LEGACY_OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex"' \
      "$MANAGER" &&
    grep -Fq 'rm -f "$LEGACY_OPENROUTER_WRAPPER"' "$MANAGER" &&
    grep -Fq 'export OPENROUTER_API_KEY=%q' "$MANAGER" &&
    grep -Fq 'base_url = "https://openrouter.ai/api/v1"' "$MANAGER" &&
    grep -Fq 'env_key = "OPENROUTER_API_KEY"' "$MANAGER" &&
    grep -Fq 'wire_api = "responses"' "$MANAGER" &&
    grep -Fq -- '--profile openrouter "$@"' "$MANAGER" &&
    grep -Fq 'Use codex normally for ChatGPT' "$MANAGER" &&
    grep -Fq 'OpenRouter fallback command: codex-openrouter' "$MANAGER" &&
    grep -Fq 'value hidden' "$MANAGER" &&
    ! grep -Fq 'cat "$OPENROUTER_ENV"' "$MANAGER"
}

first_login_onboarding_is_optional_and_repeatable() {
  grep -Fq 'onboarding-complete' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex-devbox onboard || true' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex login --device-auth' "$MANAGER" &&
    grep -Fq 'onboard() {' "$MANAGER"
}

update_preserves_user_state() {
  ! grep -Eq \
    'rm -rf[[:space:]]+("?)(/home/dev/workspace|/home/dev/\.codex|/home/dev/\.ssh)' \
    "$MANAGER" "$INSTALL_SCRIPT"
}

installer_validates_complete_stack() {
  grep -Fq 'msg_info "Validating Installation"' "$INSTALL_SCRIPT" &&
    grep -Fxq 'node --version' "$INSTALL_SCRIPT" &&
    grep -Fxq 'npm --version' "$INSTALL_SCRIPT" &&
    grep -Fxq 'codex --version' "$INSTALL_SCRIPT" &&
    grep -Fxq 'claude --version' "$INSTALL_SCRIPT" &&
    grep -Fq 'run_as_dev "${DEV_HOME}/.local/bin/mise" --version' "$INSTALL_SCRIPT" &&
    grep -Fxq 'run_as_dev elixir --version' "$INSTALL_SCRIPT" &&
    grep -Fxq 'run_as_dev mix phx.new --version' "$INSTALL_SCRIPT" &&
    grep -Fq 'systemctl is-active --quiet postgresql.service' "$INSTALL_SCRIPT" &&
    grep -Fq -- '--command "SELECT 1;"' "$INSTALL_SCRIPT" &&
    grep -Fxq '/usr/local/bin/codex-devbox doctor' "$INSTALL_SCRIPT" &&
    grep -Fq 'msg_ok "Validated Installation"' "$INSTALL_SCRIPT"
}

extract_manager

run_test "Bash syntax" scripts_have_valid_syntax
run_test "standalone, no Proxmox/community-scripts framework" standalone_no_proxmox_framework
run_test "standalone preflight checks" install_script_runs_standalone_preflight
run_test "curl-pipeable from master" installer_curl_pipeable_from_master
run_test "bare-metal install" install_script_is_bare_metal
run_test "Debian 13 Erlang toolchain" erlang_toolchain_supports_debian_13
run_test "Elixir pinned to the Erlang OTP major" elixir_is_pinned_to_the_erlang_otp_major
run_test "Claude CLI installed alongside Codex CLI" claude_cli_is_installed
run_test "doctor checks Claude CLI" doctor_checks_claude_alongside_codex
run_test "update command supports branch argument" update_command_supports_branch_argument
run_test "update downloads and reruns installer" update_downloads_and_reruns_installer
run_test "update honors the requested branch" update_branch_argument_is_honored
run_test "least-privilege developer user" developer_user_is_least_privilege
run_test "developer password only set on creation" developer_password_only_set_on_creation
run_test "writable developer home parents" developer_home_parents_are_writable
run_test "rerunning the installer is idempotent" rerunning_installer_is_idempotent
run_test "SSH key directions" ssh_onboarding_distinguishes_key_directions
run_test "unsupported CLI Remote service removed" unsupported_cli_remote_service_is_absent
run_test "platform-agnostic remote instructions" remote_instructions_are_platform_agnostic
run_test "manager command surface" manager_exposes_expected_commands
run_test "manager rejects unknown commands" manager_rejects_unknown_commands
run_test "no hardcoded default credentials" no_hardcoded_default_credentials
run_test "managed secret permissions" managed_secrets_have_restricted_permissions
run_test "selectable Codex autonomy" codex_autonomy_is_selectable_and_persisted
run_test "safe supported OpenRouter config" openrouter_configuration_is_safe_and_supported
run_test "optional repeatable onboarding" first_login_onboarding_is_optional_and_repeatable
run_test "updates preserve user state" update_preserves_user_state
run_test "complete stack validation" installer_validates_complete_stack

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
