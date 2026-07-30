#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CT_SCRIPT="${REPO_ROOT}/ct/codex-devbox.sh"
readonly INSTALL_SCRIPT="${REPO_ROOT}/install/codex-devbox-install.sh"
readonly METADATA="${REPO_ROOT}/json/codex-devbox.json"
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
  bash -n "$CT_SCRIPT" "$INSTALL_SCRIPT" "$MANAGER"
}

metadata_is_valid_json() {
  python3 -m json.tool "$METADATA" >/dev/null
}

uses_community_file_layout() {
  [[ -f "$CT_SCRIPT" ]] &&
    [[ -f "$INSTALL_SCRIPT" ]] &&
    [[ -f "$METADATA" ]] &&
    [[ ! -e "${REPO_ROOT}/codex-devbox.sh" ]] &&
    grep -Fq 'COMMUNITY_FRAMEWORK_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"' \
      "$CT_SCRIPT" &&
    grep -Fq 'CODEX_DEVBOX_SOURCE_URL' "$CT_SCRIPT" &&
    ! grep -Fq 'community-scripts/ProxmoxVED' "$CT_SCRIPT" &&
    grep -Fq 'source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"' "$INSTALL_SCRIPT"
}

ct_script_has_standard_defaults() {
  grep -Fq 'APP="Codex-DevBox"' "$CT_SCRIPT" &&
    grep -Fq 'var_cpu="${var_cpu:-4}"' "$CT_SCRIPT" &&
    grep -Fq 'var_ram="${var_ram:-8192}"' "$CT_SCRIPT" &&
    grep -Fq 'var_disk="${var_disk:-32}"' "$CT_SCRIPT" &&
    grep -Fq 'var_os="${var_os:-debian}"' "$CT_SCRIPT" &&
    grep -Fq 'var_version="${var_version:-13}"' "$CT_SCRIPT" &&
    grep -Fq 'var_arm64="${var_arm64:-no}"' "$CT_SCRIPT" &&
    grep -Fq 'var_unprivileged="${var_unprivileged:-1}"' "$CT_SCRIPT"
}

ct_app_name_maps_to_installer() {
  local app
  local installer_slug

  app="$(sed -n 's/^APP="\([^"]*\)"$/\1/p' "$CT_SCRIPT")"
  installer_slug="$(tr '[:upper:]' '[:lower:]' <<<"$app" | tr -d ' ')"

  [[ "${installer_slug}-install.sh" == "$(basename "$INSTALL_SCRIPT")" ]]
}

preview_source_routes_framework_and_installer() {
  local preview_root="${TEST_TMP}/preview"
  local preview_log="${preview_root}/fetch.log"

  mkdir -p "${preview_root}/bin" "${preview_root}/ct"
  cp "$CT_SCRIPT" "${preview_root}/ct/codex-devbox.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"$PREVIEW_LOG"' \
    'cat <<'\''BUILD_FUNC'\''' \
    'header_info() { :; }' \
    'variables() { var_install="codex-devbox-install"; }' \
    'color() { :; }' \
    'catch_errors() { :; }' \
    'msg_ok() { :; }' \
    'start() { :; }' \
    'description() { :; }' \
    'build_container() {' \
    '  curl -fsSL "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func" >/dev/null' \
    '  curl -fsSL "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/${var_install}.sh" >/dev/null' \
    '}' \
    'BUILD_FUNC' >"${preview_root}/bin/curl"
  chmod 0755 "${preview_root}/bin/curl"

  CODEX_DEVBOX_SOURCE_URL="https://example.test/codex-devbox" \
    PREVIEW_LOG="$preview_log" \
    PATH="${preview_root}/bin:/usr/bin:/bin" \
    bash "${preview_root}/ct/codex-devbox.sh" >/dev/null

  grep -Fq \
    'https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func' \
    "$preview_log" &&
    grep -Fq \
    'https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func' \
    "$preview_log" &&
    grep -Fq \
      'https://example.test/codex-devbox/install/codex-devbox-install.sh' \
      "$preview_log"
}

framework_download_failure_is_explicit() {
  local preview_root="${TEST_TMP}/download-failure"
  local output_file="${preview_root}/output.log"
  local status=0

  mkdir -p "${preview_root}/bin" "${preview_root}/ct"
  cp "$CT_SCRIPT" "${preview_root}/ct/codex-devbox.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 22' >"${preview_root}/bin/curl"
  chmod 0755 "${preview_root}/bin/curl"

  PATH="${preview_root}/bin:/usr/bin:/bin" \
    bash "${preview_root}/ct/codex-devbox.sh" \
    >"$output_file" 2>&1 || status=$?

  [[ "$status" -eq 115 ]] &&
    grep -Fq \
      'FATAL: Failed to download the Community Scripts framework.' \
      "$output_file" &&
    ! grep -Fq 'command not found' "$output_file"
}

ct_script_uses_standard_orchestration() {
  grep -Fq 'header_info "$APP"' "$CT_SCRIPT" &&
    grep -Fxq 'variables' "$CT_SCRIPT" &&
    grep -Fxq 'color' "$CT_SCRIPT" &&
    grep -Fxq 'catch_errors' "$CT_SCRIPT" &&
    grep -Fxq 'start' "$CT_SCRIPT" &&
    grep -Fxq 'build_container' "$CT_SCRIPT" &&
    grep -Fxq 'description' "$CT_SCRIPT"
}

ct_script_has_update_path() {
  grep -Fq 'function update_script()' "$CT_SCRIPT" &&
    grep -Fq 'check_container_storage' "$CT_SCRIPT" &&
    grep -Fq 'check_container_resources' "$CT_SCRIPT" &&
    grep -Fq '/usr/local/bin/codex-devbox update' "$CT_SCRIPT"
}

ct_script_does_not_duplicate_proxmox_core() {
  ! grep -Eq \
    'whiptail|pct create|pveam|pvesm|pvesh get /cluster/nextid|create_container\(' \
    "$CT_SCRIPT"
}

install_script_uses_community_lifecycle() {
  grep -Fxq 'color' "$INSTALL_SCRIPT" &&
    grep -Fxq 'verb_ip6' "$INSTALL_SCRIPT" &&
    grep -Fxq 'catch_errors' "$INSTALL_SCRIPT" &&
    grep -Fxq 'setting_up_container' "$INSTALL_SCRIPT" &&
    grep -Fxq 'network_check' "$INSTALL_SCRIPT" &&
    grep -Fxq 'update_os' "$INSTALL_SCRIPT" &&
    grep -Fxq 'motd_ssh' "$INSTALL_SCRIPT" &&
    grep -Fxq 'customize' "$INSTALL_SCRIPT" &&
    grep -Fxq 'cleanup_lxc' "$INSTALL_SCRIPT" &&
    [[ "$(tail -n 3 "$INSTALL_SCRIPT")" == $'motd_ssh\ncustomize\ncleanup_lxc' ]]
}

install_script_uses_tools_helpers() {
  grep -Fq 'setup_nodejs' "$INSTALL_SCRIPT" &&
    grep -Fq 'setup_postgresql' "$INSTALL_SCRIPT" &&
    grep -Fq 'setup_postgresql_db' "$INSTALL_SCRIPT" &&
    grep -Fq 'curl_with_retry "https://mise.run"' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'deb.nodesource.com' "$INSTALL_SCRIPT"
}

install_script_is_bare_metal() {
  ! grep -Eq 'setup_docker|docker (run|compose|pull)|podman' "$INSTALL_SCRIPT"
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

ssh_onboarding_distinguishes_key_directions() {
  grep -Fq 'A private client key must' "$INSTALL_SCRIPT" &&
    grep -Fq 'SSH_AUTHORIZED_KEY' "$INSTALL_SCRIPT" &&
    grep -Fq 'keys generate' "$INSTALL_SCRIPT" &&
    grep -Fq 'ssh-keygen' "$INSTALL_SCRIPT" &&
    grep -Fq 'keys upload-github' "$INSTALL_SCRIPT"
}

unsupported_cli_remote_service_is_absent() {
  ! grep -Eq \
    'codex remote-control|codex-remote-control\.service|app-server-control\.sock' \
    "$CT_SCRIPT" "$INSTALL_SCRIPT"
}

remote_instructions_use_supported_path() {
  local output

  output="$("$MANAGER" remote-info)"
  grep -Fq 'ChatGPT on iOS' <<<"$output" &&
    grep -Fq 'ChatGPT desktop app on macOS or Windows' <<<"$output" &&
    grep -Fq 'SSH connection' <<<"$output" &&
    grep -Fq 'pct enter <CTID>' <<<"$output"
}

manager_exposes_expected_commands() {
  local output

  output="$("$MANAGER" --help)"
  grep -Fq 'onboard' <<<"$output" &&
    grep -Fq 'ssh setup' <<<"$output" &&
    grep -Fq 'auth login' <<<"$output" &&
    grep -Fq 'github setup' <<<"$output" &&
    grep -Fq 'keys generate' <<<"$output" &&
    grep -Fq 'remote-info' <<<"$output" &&
    grep -Fq 'doctor' <<<"$output" &&
    grep -Fq 'update' <<<"$output"
}

manager_rejects_unknown_commands() {
  local status=0

  "$MANAGER" does-not-exist >/dev/null 2>&1 || status=$?
  [[ "$status" -eq 2 ]]
}

metadata_matches_scripts() {
  python3 - "$METADATA" "$CT_SCRIPT" <<'PY'
import json
import pathlib
import sys

metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
ct_script = pathlib.Path(sys.argv[2]).read_text()

resources = metadata["install_methods"][0]["resources"]
assert metadata["name"] == "Codex DevBox"
assert metadata["slug"] == "codex-devbox"
assert metadata["type"] == "ct"
assert metadata["updateable"] is True
assert metadata["privileged"] is False
assert metadata["has_arm"] is False
assert metadata["interface_port"] is None
assert metadata["categories"] == [20]
assert metadata["config_path"] == "/home/dev/.config/codex-devbox"
assert metadata["install_methods"][0]["script"] == "ct/codex-devbox.sh"
assert resources == {
    "cpu": 4,
    "ram": 8192,
    "hdd": 32,
    "os": "Debian",
    "version": "13",
}
for value in ('var_cpu="${var_cpu:-4}"',
              'var_ram="${var_ram:-8192}"',
              'var_disk="${var_disk:-32}"',
              'var_os="${var_os:-debian}"',
              'var_version="${var_version:-13}"',
              'var_arm64="${var_arm64:-no}"'):
    assert value in ct_script
PY
}

no_hardcoded_default_credentials() {
  python3 - "$METADATA" <<'PY'
import json
import pathlib
import sys

metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert metadata["default_credentials"] == {
    "username": None,
    "password": None,
}
PY
  ! grep -Eq \
    'PASSWORD=(postgres|password|changeme)|password["'\'']?[[:space:]]*[:=][[:space:]]*["'\'']?(postgres|password|changeme)' \
    "$CT_SCRIPT" "$INSTALL_SCRIPT"
}

managed_secrets_have_restricted_permissions() {
  grep -Fq 'chmod 0600' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.pgpass"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.config/codex-devbox/postgres.env"' \
      "$INSTALL_SCRIPT"
}

first_login_onboarding_is_optional_and_repeatable() {
  grep -Fq 'onboarding-complete' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex-devbox onboard || true' "$INSTALL_SCRIPT" &&
    grep -Fq 'codex login --device-auth' "$MANAGER" &&
    grep -Fq 'onboard() {' "$MANAGER"
}

update_preserves_user_state() {
  grep -Fq 'Updating Codex CLI' "$MANAGER" &&
    grep -Fq 'Ensuring managed Erlang, Elixir and Phoenix versions' "$MANAGER" &&
    ! grep -Eq \
      'rm -rf[[:space:]]+("?)(/home/dev/workspace|/home/dev/\.codex|/home/dev/\.ssh)' \
      "$MANAGER"
}

extract_manager

run_test "Bash syntax" scripts_have_valid_syntax
run_test "metadata JSON" metadata_is_valid_json
run_test "Community file layout" uses_community_file_layout
run_test "standard CT defaults" ct_script_has_standard_defaults
run_test "APP maps to installer filename" ct_app_name_maps_to_installer
run_test "preview source routing" preview_source_routes_framework_and_installer
run_test "explicit framework download failure" framework_download_failure_is_explicit
run_test "standard CT orchestration" ct_script_uses_standard_orchestration
run_test "standard update path" ct_script_has_update_path
run_test "no duplicated Proxmox core" ct_script_does_not_duplicate_proxmox_core
run_test "install lifecycle" install_script_uses_community_lifecycle
run_test "tools.func helpers" install_script_uses_tools_helpers
run_test "bare-metal install" install_script_is_bare_metal
run_test "least-privilege developer user" developer_user_is_least_privilege
run_test "SSH key directions" ssh_onboarding_distinguishes_key_directions
run_test "unsupported CLI Remote service removed" unsupported_cli_remote_service_is_absent
run_test "supported mobile connection instructions" remote_instructions_use_supported_path
run_test "manager command surface" manager_exposes_expected_commands
run_test "manager rejects unknown commands" manager_rejects_unknown_commands
run_test "metadata matches scripts" metadata_matches_scripts
run_test "no hardcoded default credentials" no_hardcoded_default_credentials
run_test "managed secret permissions" managed_secrets_have_restricted_permissions
run_test "optional repeatable onboarding" first_login_onboarding_is_optional_and_repeatable
run_test "updates preserve user state" update_preserves_user_state

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
