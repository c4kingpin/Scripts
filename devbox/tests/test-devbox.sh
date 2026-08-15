#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
readonly INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"
TEST_TMP="$(mktemp -d /tmp/devbox-tests.XXXXXX)"
readonly TEST_TMP
readonly MANAGER="${TEST_TMP}/devbox"

PASSED=0
FAILED=0

cleanup() {
  if [[ "$TEST_TMP" == /tmp/devbox-tests.* && -d "$TEST_TMP" ]]; then
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
    /^cat <<'\''MANAGER'\'' >\/usr\/local\/bin\/devbox$/ {
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

# install.sh and the generated manager write one argument per line (backslash
# continuations) for readability. Fixed-string greps for a whole logical
# command therefore need a joined-up view of the script; this produces one.
normalize_continuations() {
  awk '{
    line = $0
    if (cont) { sub(/^[ \t]+/, "", line) }
    if (sub(/[ \t]*\\[ \t]*$/, "", line)) {
      printf "%s ", line
      cont = 1
    } else {
      print line
      cont = 0
    }
  }' "$1"
}

readonly NORM_INSTALL="${TEST_TMP}/install.normalized"
readonly NORM_MANAGER="${TEST_TMP}/devbox.normalized"

scripts_have_valid_syntax() {
  bash -n "$INSTALL_SCRIPT" "$MANAGER"
}

standalone_no_proxmox_framework() {
  [[ -f "$INSTALL_SCRIPT" ]] &&
    ! grep -Eq \
      'FUNCTIONS_FILE_PATH|build_container\(\)|COMMUNITY_FRAMEWORK_URL|ProxmoxVED|whiptail|pct create|pveam|pvesm|pvesh get /cluster/nextid|create_container\(' \
      "$INSTALL_SCRIPT"
}

# The repository holds several scripts, so this project keeps everything it
# owns inside devbox/ and the download URLs must point at that path.
project_is_self_contained() {
  [[ "$(basename "$PROJECT_ROOT")" == "devbox" ]] &&
    [[ -f "${PROJECT_ROOT}/install.sh" ]] &&
    [[ -f "${PROJECT_ROOT}/README.md" ]] &&
    [[ -f "${PROJECT_ROOT}/tests/test-devbox.sh" ]] &&
    grep -Fq '${repo_url%/}/${branch}/devbox/install.sh' "$INSTALL_SCRIPT" &&
    ! grep -Eq 'Scripts/(master|\$\{branch\})/install\.sh' "$INSTALL_SCRIPT"
}

install_script_runs_standalone_preflight() {
  grep -Fq 'require_root() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'require_supported_os() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'network_check() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'update_os() {' "$INSTALL_SCRIPT" &&
    grep -Fxq 'require_root' "$INSTALL_SCRIPT" &&
    grep -Fxq 'require_supported_os' "$INSTALL_SCRIPT" &&
    grep -Fxq 'network_check' "$INSTALL_SCRIPT" &&
    grep -Fxq 'update_os' "$INSTALL_SCRIPT"
}

installer_curl_pipeable_from_master() {
  # The one-liner lives in the docs, not in a header comment inside
  # install.sh itself.
  grep -Fq 'curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh | bash' \
    "${PROJECT_ROOT}/README.md"
}

install_script_is_bare_metal() {
  ! grep -Eq 'setup_docker|docker (run|compose|pull)|podman' "$INSTALL_SCRIPT"
}

# mise is installed as a general-purpose version manager, but the BEAM
# toolchain must not go through it: its shims produced a runtime that died
# during kernel startup. Erlang and Elixir live in /opt and are reached by
# plain symlinks in /usr/local/bin.
toolchain_is_installed_outside_the_version_manager() {
  grep -Fq 'OTP_ROOT="/opt/devbox/otp"' "$INSTALL_SCRIPT" &&
    grep -Fq 'ELIXIR_ROOT="/opt/devbox/elixir"' "$INSTALL_SCRIPT" &&
    grep -Fq './Install -minimal "$OTP_ROOT"' "$NORM_INSTALL" &&
    grep -Fq 'ln -sfn "${OTP_ROOT}/bin/${otp_bin}" "/usr/local/bin/${otp_bin}"' \
      "$NORM_INSTALL" &&
    grep -Fq 'ln -sfn "${ELIXIR_ROOT}/bin/${elixir_bin}" "/usr/local/bin/${elixir_bin}"' \
      "$NORM_INSTALL" &&
    # mise must never be told to provide erlang or elixir ...
    ! grep -Eq 'mise[^\n]*(use|exec|reshim)[^\n]*(erlang|elixir)' "$INSTALL_SCRIPT" &&
    ! grep -Eq 'MISE_ERLANG|erlang@|elixir@' "$INSTALL_SCRIPT" &&
    # ... and its shims must stay off the PATH the installer hands to dev.
    ! grep -Fq 'mise/shims:' "$INSTALL_SCRIPT"
}

# mise stays available for other languages a project may need.
mise_is_available_as_a_developer_tool() {
  grep -Fq 'curl_with_retry "https://mise.run" "$mise_installer"' "$NORM_INSTALL" &&
    grep -Fq 'MISE_INSTALL_PATH="${DEV_HOME}/.local/bin/mise"' "$INSTALL_SCRIPT"
}

# OTP 28 crashed on boot in this container class; 27.3.x is the verified one.
erlang_is_pinned_to_a_verified_release() {
  grep -Fq 'ERLANG_VERSION="${ERLANG_VERSION:-27.' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'ERLANG_VERSION="28' "$INSTALL_SCRIPT"
}

erlang_comes_from_the_precompiled_ubuntu_build() {
  grep -Fq 'builds.hex.pm/builds/otp/${otp_arch}/${otp_os}/OTP-${ERLANG_VERSION}.tar.gz' \
    "$INSTALL_SCRIPT" &&
    grep -Fq 'otp_arch="$(dpkg --print-architecture)"' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'KERL_CONFIGURE_OPTIONS' "$INSTALL_SCRIPT" &&
    grep -Fq "run_as_dev erl -noshell -eval 'halt(0).'" "$NORM_INSTALL"
}

# Erlang writes ~/.erlang.cookie when the kernel application starts; an
# unwritable HOME took the whole runtime down during the original failure.
erlang_cookie_is_provisioned() {
  grep -Fq '"${DEV_HOME}/.erlang.cookie"' "$INSTALL_SCRIPT" &&
    grep -Fq 'chmod 0400 "${DEV_HOME}/.erlang.cookie"' "$NORM_INSTALL" &&
    grep -Fq 'HOME="$DEV_HOME"' "$INSTALL_SCRIPT"
}

installer_requires_ubuntu() {
  grep -Fq 'require_supported_os() {' "$INSTALL_SCRIPT" &&
    grep -Fxq 'require_supported_os' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'require_debian_like' "$INSTALL_SCRIPT" &&
    grep -Fq 'ubuntu-24.04 | ubuntu-22.04 | ubuntu-20.04)' "$INSTALL_SCRIPT" &&
    grep -Fq 'add-apt-repository -y universe' "$NORM_INSTALL"
}

elixir_is_pinned_to_the_erlang_otp_major() {
  # Elixir releases are published per OTP major, so deriving the artifact from
  # ERLANG_VERSION keeps the pair from drifting apart on version bumps.
  grep -Fq 'ERLANG_OTP_MAJOR="${ERLANG_VERSION%%.*}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'releases/download/v${ELIXIR_VERSION}/elixir-otp-${ERLANG_OTP_MAJOR}.zip' \
      "$INSTALL_SCRIPT"
}

claude_cli_is_installed() {
  grep -Fq 'npm install --global @anthropic-ai/claude-code@latest' "$NORM_INSTALL" &&
    grep -Fq 'npm install --global @openai/codex@latest' "$NORM_INSTALL" &&
    grep -Fq 'claude' "$MANAGER" &&
    # Agent CLIs are runtime tools for the dev account, so the installer's
    # own final validation step runs them via run_as_dev, not bare.
    grep -Fq 'run_as_dev claude --version' "$NORM_INSTALL" &&
    grep -Fq 'run_as_dev claude --version' "$NORM_MANAGER"
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
    grep -Fq 'local installer_url="${repo_url%/}/${branch}/devbox/install.sh"' "$MANAGER" &&
    grep -Fq 'update:*)' "$MANAGER" &&
    grep -Fq 'update_devbox "$subcommand"' "$MANAGER" &&
    grep -Fq 'update [branch]' "$MANAGER"
}

update_downloads_and_reruns_installer() {
  grep -Fq 'curl -fsSL --connect-timeout 15 --retry 5 --retry-connrefused' "$NORM_MANAGER" &&
    grep -Fq 'bash "$installer"' "$NORM_MANAGER" &&
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
*/feature-branch/devbox/install.sh)
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
  # SSH policy is scoped to a `Match User dev` block (not a global
  # AllowUsers directive), so administrative/root SSH access is never
  # touched by DevBox.
  grep -Fq 'useradd --create-home --user-group --shell /bin/bash' \
    "$NORM_INSTALL" &&
    grep -Fq 'Match User dev' "$INSTALL_SCRIPT" &&
    grep -Fq 'PasswordAuthentication no' "$INSTALL_SCRIPT" &&
    grep -Fq 'AuthenticationMethods publickey' "$INSTALL_SCRIPT" &&
    ! grep -Eq '^AllowUsers[[:space:]]+dev([[:space:]]|$)' "$INSTALL_SCRIPT" &&
    grep -Fq \
      '${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/devbox ssh setup' \
      "$NORM_INSTALL" &&
    ! grep -Eq 'NOPASSWD:[[:space:]]*ALL' "$INSTALL_SCRIPT"
}

developer_password_only_set_on_creation() {
  python3 - "$NORM_INSTALL" <<'PY'
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
  local toolchain_line
  local permissions_root="${TEST_TMP}/permissions"

  # Each install -d entry is one argument per line ending in a backslash;
  # anchor on that trailing backslash so this only matches the entry that
  # actually creates the directory, not the migration guard that also names
  # the same path (on a line ending in "]]; then" instead).
  # shellcheck disable=SC1003
  config_line="$(grep -nF '"${DEV_HOME}/.config" \' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"
  # shellcheck disable=SC1003
  state_line="$(grep -nF '"${DEV_HOME}/.config/devbox" \' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"
  toolchain_line="$(grep -nF 'OTP_ROOT="/opt/devbox/otp"' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"

  grep -Fq 'run_as_dev test -w "$developer_dir"' "$NORM_INSTALL" &&
    grep -Fq 'Developer directory is not writable:' "$INSTALL_SCRIPT" ||
    return 1

  [[ -n "$config_line" && -n "$state_line" && -n "$toolchain_line" ]] &&
    ((config_line < state_line && state_line < toolchain_line)) &&
    grep -Fq '"${DEV_HOME}/.cache"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.local"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.local/bin"' "$INSTALL_SCRIPT" || return 1

  install -d -m 0500 "${permissions_root}/.config"
  if mkdir "${permissions_root}/.config/devbox" 2>/dev/null; then
    return 1
  fi
  chmod 0700 "${permissions_root}/.config"
  mkdir "${permissions_root}/.config/devbox"
}

rerunning_installer_is_idempotent() {
  grep -Fq "if ! grep -Fq '# DevBox' \"\${DEV_HOME}/.bashrc\"" "$NORM_INSTALL" &&
    grep -Fq 'if [[ ! -f "${DEV_HOME}/.codex/config.toml" ]]; then' "$INSTALL_SCRIPT" &&
    grep -Fq 'if [[ ! -f "${DEV_HOME}/.claude/settings.json" ]]; then' "$INSTALL_SCRIPT" &&
    # A re-run without SSH_AUTHORIZED_KEY or a disabled marker leaves an
    # already-managed SSH policy alone instead of clobbering it.
    grep -Fq 'elif [[ -e "$SSH_DISABLED_MARKER" ]]; then' "$INSTALL_SCRIPT" &&
    grep -Fq "SELECT 1 FROM pg_roles WHERE rolname = '\${PG_DB_USER}'" "$INSTALL_SCRIPT" &&
    grep -Fq "SELECT 1 FROM pg_database WHERE datname = '\${PG_DB_NAME}'" "$INSTALL_SCRIPT" &&
    grep -Fq "grep -q '^PGPASSWORD='" "$NORM_INSTALL"
}

# Everything the old name owned must be carried over or removed; the state
# directory holds the only copy of the DB password and the OpenRouter key.
renaming_migrates_existing_installations() {
  grep -Fq 'mv "${DEV_HOME}/.config/codex-devbox" "${DEV_HOME}/.config/devbox"' \
    "$INSTALL_SCRIPT" &&
    grep -Fq '/usr/local/bin/codex-devbox' "$INSTALL_SCRIPT" &&
    grep -Fq '/etc/sudoers.d/90-codex-devbox' "$INSTALL_SCRIPT" &&
    grep -Fq '/etc/ssh/sshd_config.d/00-codex-devbox.conf' "$INSTALL_SCRIPT" &&
    grep -Fq '/etc/profile.d/codex-devbox.sh' "$INSTALL_SCRIPT" &&
    grep -Fq "s/# Codex Dev Box/# DevBox/" "$INSTALL_SCRIPT" &&
    grep -Eq 'Managed by \(devbox\|codex-devbox\) openrouter setup' "$MANAGER"
}

# The rename must not leave the old command, paths or env vars behind.
old_name_is_gone_from_the_active_surface() {
  ! grep -Fq 'CODEX_DEVBOX_REPO_URL' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'CODEX_AUTONOMY' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'Usage: codex-devbox' "$MANAGER" &&
    grep -Fq 'Usage: devbox COMMAND' "$MANAGER" &&
    grep -Fq 'cat <<'\''MANAGER'\'' >/usr/local/bin/devbox' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_REPO_URL' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_AUTONOMY' "$INSTALL_SCRIPT"
}

ssh_onboarding_distinguishes_key_directions() {
  grep -Fq 'Never copy a private key here.' "$INSTALL_SCRIPT" &&
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

# Happy is now the primary remote/session layer (replacing the older
# ChatGPT-desktop-as-SSH-bridge flow), so `devbox remote-info` documents
# Happy's pairing and daemon commands instead of a host-console walkthrough.
remote_instructions_are_platform_agnostic() {
  local output

  output="$("$MANAGER" remote-info)"
  grep -Fq 'Happy remote development' <<<"$output" &&
    grep -Fq 'happy claude' <<<"$output" &&
    grep -Fq 'happy codex' <<<"$output" &&
    grep -Fq 'devbox auth login' <<<"$output" &&
    grep -Fq 'devbox ssh setup' <<<"$output"
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
  grep -Fq 'chmod 0600' "$NORM_INSTALL" &&
    grep -Fq '"${DEV_HOME}/.pgpass"' "$INSTALL_SCRIPT" &&
    grep -Fq '"$PG_ENV_FILE"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.codex/config.toml"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.claude/settings.json"' "$INSTALL_SCRIPT" &&
    grep -Fq 'chmod 0600 "$OPENROUTER_ENV"' "$NORM_MANAGER"
}

# One profile must configure both agents, or they would drift apart.
autonomy_is_selectable_and_applies_to_both_agents() {
  grep -Fq 'select_autonomy() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_AUTONOMY' "$INSTALL_SCRIPT" &&
    grep -Fq 'How autonomously may Codex and Claude work?' "$INSTALL_SCRIPT" &&
    grep -Fq '"defaultMode": "${claude_default_mode}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'claude_default_mode="default"' "$INSTALL_SCRIPT" &&
    grep -Fq 'claude_default_mode="acceptEdits"' "$INSTALL_SCRIPT" &&
    grep -Fq 'claude_default_mode="auto"' "$INSTALL_SCRIPT" &&
    grep -Fq 'claude_default_mode="bypassPermissions"' "$INSTALL_SCRIPT" &&
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
    grep -Fq 'read -r -s -p "OpenRouter API key: "' "$NORM_MANAGER" &&
    grep -Fq 'OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex-openrouter"' \
      "$MANAGER" &&
    grep -Fq 'LEGACY_OPENROUTER_WRAPPER="${DEV_HOME}/.local/bin/codex"' \
      "$MANAGER" &&
    grep -Fq 'rm -f "$LEGACY_OPENROUTER_WRAPPER"' "$NORM_MANAGER" &&
    grep -Fq 'export OPENROUTER_API_KEY=%q' "$MANAGER" &&
    grep -Fq 'base_url = "https://openrouter.ai/api/v1"' "$MANAGER" &&
    grep -Fq 'env_key = "OPENROUTER_API_KEY"' "$MANAGER" &&
    grep -Fq 'wire_api = "responses"' "$MANAGER" &&
    grep -Fq -- '--profile openrouter "$@"' "$NORM_MANAGER" &&
    # Happy is now the primary agent entry point, so the fallback summary
    # names Happy/native/fallback rather than talking about ChatGPT.
    grep -Fq 'info "Primary: happy codex"' "$NORM_MANAGER" &&
    grep -Fq 'OpenRouter fallback command: codex-openrouter' "$MANAGER" &&
    grep -Fq 'value hidden' "$MANAGER" &&
    ! grep -Fq 'cat "$OPENROUTER_ENV"' "$MANAGER"
}

first_login_onboarding_is_optional_and_repeatable() {
  grep -Fq 'onboarding-complete' "$INSTALL_SCRIPT" &&
    grep -Fq 'devbox onboard || true' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex login --device-auth' "$NORM_MANAGER" &&
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
    # Agent CLIs are runtime tools for the dev account, so validation runs
    # them via run_as_dev rather than bare as root.
    grep -Fq 'run_as_dev codex --version' "$NORM_INSTALL" &&
    grep -Fq 'run_as_dev claude --version' "$NORM_INSTALL" &&
    grep -Fq "run_as_dev erl -noshell -eval 'halt(0).'" "$NORM_INSTALL" &&
    grep -Fq 'run_as_dev elixir --version' "$NORM_INSTALL" &&
    grep -Fq 'run_as_dev mix phx.new --version' "$NORM_INSTALL" &&
    grep -Fq 'systemctl is-active --quiet postgresql.service' "$NORM_INSTALL" &&
    grep -Fq -- '--command "SELECT 1;"' "$INSTALL_SCRIPT" &&
    grep -Fxq '/usr/local/bin/devbox doctor' "$INSTALL_SCRIPT" &&
    grep -Fq 'msg_ok "Validated Installation"' "$INSTALL_SCRIPT"
}

extract_manager
normalize_continuations "$INSTALL_SCRIPT" >"$NORM_INSTALL"
normalize_continuations "$MANAGER" >"$NORM_MANAGER"

run_test "Bash syntax" scripts_have_valid_syntax
run_test "standalone, no Proxmox/community-scripts framework" standalone_no_proxmox_framework
run_test "standalone preflight checks" install_script_runs_standalone_preflight
run_test "curl-pipeable from master" installer_curl_pipeable_from_master
run_test "project is self-contained under devbox/" project_is_self_contained
run_test "bare-metal install" install_script_is_bare_metal
run_test "BEAM toolchain outside the version manager" toolchain_is_installed_outside_the_version_manager
run_test "mise available as a developer tool" mise_is_available_as_a_developer_tool
run_test "Erlang pinned to a verified release" erlang_is_pinned_to_a_verified_release
run_test "precompiled Ubuntu Erlang build" erlang_comes_from_the_precompiled_ubuntu_build
run_test "Erlang cookie provisioned" erlang_cookie_is_provisioned
run_test "installer requires Ubuntu" installer_requires_ubuntu
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
run_test "autonomy applies to both agents" autonomy_is_selectable_and_applies_to_both_agents
run_test "safe supported OpenRouter config" openrouter_configuration_is_safe_and_supported
run_test "optional repeatable onboarding" first_login_onboarding_is_optional_and_repeatable
run_test "updates preserve user state" update_preserves_user_state
run_test "complete stack validation" installer_validates_complete_stack

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
