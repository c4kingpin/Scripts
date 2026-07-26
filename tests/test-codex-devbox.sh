#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

# shellcheck source=codex-devbox.sh
source "${SCRIPT_DIR}/codex-devbox.sh"

TEST_TMP="$(mktemp -d /tmp/codex-devbox-tests.XXXXXX)"
PASSED=0
FAILED=0

cleanup() {
  if [[ "$TEST_TMP" == /tmp/codex-devbox-tests.* && -d "$TEST_TMP" ]]; then
    rm -rf -- "$TEST_TMP"
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

accepts_valid_ipv4() {
  is_ipv4 "0.0.0.0" &&
    is_ipv4 "192.168.10.42" &&
    is_ipv4 "255.255.255.255"
}

rejects_invalid_ipv4() {
  ! is_ipv4 "256.1.1.1" &&
    ! is_ipv4 "192.168.1" &&
    ! is_ipv4 "192.168.1.1.5" &&
    ! is_ipv4 "192.168.-1.1" &&
    ! is_ipv4 "192.168.001.1" &&
    ! is_ipv4 "192.168.1.1/24"
}

validates_ipv4_cidr() {
  is_ipv4_cidr "10.0.0.1/0" &&
    is_ipv4_cidr "10.0.0.1/32" &&
    ! is_ipv4_cidr "10.0.0.1/33" &&
    ! is_ipv4_cidr "300.0.0.1/24" &&
    ! is_ipv4_cidr "10.0.0.1"
}

validates_static_network_semantics() {
  static_network_is_usable "192.168.10.42/24" "192.168.10.1" &&
    static_network_is_usable "10.20.30.2/30" "10.20.30.1" &&
    ! static_network_is_usable "192.168.10.0/24" "192.168.10.1" &&
    ! static_network_is_usable "192.168.10.255/24" "192.168.10.1" &&
    ! static_network_is_usable "192.168.10.42/24" "192.168.11.1" &&
    ! static_network_is_usable "192.168.10.42/24" "192.168.10.42" &&
    ! static_network_is_usable "192.168.10.42/32" "192.168.10.1"
}

converts_ipv4_to_integer() {
  [[ "$(ipv4_to_int "0.0.0.0")" == "0" ]] &&
    [[ "$(ipv4_to_int "192.168.1.10")" == "3232235786" ]] &&
    [[ "$(ipv4_to_int "255.255.255.255")" == "4294967295" ]]
}

parses_supported_pve_versions() {
  [[ "$(pve_major_version \
    'pve-manager/8.4.1/2a5fa54a8503f96d (running kernel: 6.8.12-9-pve)')" == \
    "8" ]] &&
    [[ "$(pve_major_version \
      'pve-manager/9.2.3/d0fde103346cf89a (running kernel: 7.0.12-1-pve)')" == \
      "9" ]] &&
    ! pve_major_version "proxmox-ve: unknown"
}

validates_real_ssh_key() {
  local public_key

  ssh-keygen \
    -q \
    -t ed25519 \
    -N "" \
    -f "${TEST_TMP}/id_ed25519"
  public_key="$(<"${TEST_TMP}/id_ed25519.pub")"

  validate_ssh_public_key "$public_key" &&
    [[ "$(ssh_public_key_fingerprint "$public_key")" == SHA256:* ]]
}

rejects_malformed_ssh_keys() {
  ! validate_ssh_public_key "ssh-ed25519 not-base64" &&
    ! validate_ssh_public_key $'ssh-ed25519 AAAA\ncommand="id"' &&
    ! validate_ssh_public_key "ssh-dss AAAAB3NzaC1kc3MAAACB"
}

pct() {
  return 1
}

pvesh() {
  if [[ "$*" == "get /cluster/nextid --vmid 123" ]]; then
    printf '123\n'
    return 0
  fi
  return 1
}

storage_is_active() {
  return 0
}

storage_available_kib() {
  printf '104857600\n'
}

bridge_exists() {
  return 0
}

set_valid_settings() {
  CTID="123"
  CORES="4"
  MEMORY="8192"
  SWAP="512"
  DISK="32"
  CT_HOSTNAME="codex-devbox"
  DEV_USER="dev"
  BRIDGE="vmbr0"
  ALLOW_AGENT_FORWARDING="no"
  IPV4_MODE="dhcp"
  IPV4_ADDRESS=""
  IPV4_GATEWAY=""
  STORAGE="local-lvm"
  TEMPLATE_STORAGE="local"
}

accepts_valid_settings() {
  set_valid_settings
  validate_settings
}

rejects_root_user() {
  if (
    set_valid_settings
    DEV_USER="root"
    validate_settings
  ) >/dev/null 2>&1; then
    return 1
  fi
}

rejects_invalid_static_network() {
  if (
    set_valid_settings
    IPV4_MODE="static"
    IPV4_ADDRESS="999.168.1.50/24"
    IPV4_GATEWAY="192.168.1.1"
    validate_settings
  ) >/dev/null 2>&1; then
    return 1
  fi
}

accepts_usable_static_network() {
  set_valid_settings
  IPV4_MODE="static"
  IPV4_ADDRESS="192.168.10.42/24"
  IPV4_GATEWAY="192.168.10.1"
  validate_settings
}

rejects_unusable_static_network() {
  if (
    set_valid_settings
    IPV4_MODE="static"
    IPV4_ADDRESS="192.168.10.42/24"
    IPV4_GATEWAY="192.168.11.1"
    validate_settings
  ) >/dev/null 2>&1; then
    return 1
  fi
}

rejects_undersized_resources() {
  if (
    set_valid_settings
    MEMORY="1024"
    validate_settings
  ) >/dev/null 2>&1; then
    return 1
  fi

  if (
    set_valid_settings
    DISK="8"
    validate_settings
  ) >/dev/null 2>&1; then
    return 1
  fi
}

checks_vmid_cluster_wide() {
  vmid_is_available "123" &&
    ! vmid_is_available "124"
}

rejects_occupied_vmid() {
  if (
    set_valid_settings
    CTID="124"
    validate_settings
  ) >/dev/null 2>&1; then
    return 1
  fi
}

rejects_missing_storage_capacity() {
  if (
    set_valid_settings
    # shellcheck disable=SC2329
    storage_available_kib() {
      printf '1024\n'
    }
    validate_settings
  ) >/dev/null 2>&1; then
    return 1
  fi
}

rejects_unknown_option() {
  local status=0

  bash "${SCRIPT_DIR}/codex-devbox.sh" --does-not-exist >/dev/null 2>&1 ||
    status=$?
  [[ "$status" -eq 2 ]]
}

reports_current_version_and_lts_default() {
  [[ "$(bash "${SCRIPT_DIR}/codex-devbox.sh" --version)" == \
    "Codex Dev Box 1.2.2" ]] &&
    grep -Fq "readonly NODE_MAJOR=\"\${NODE_MAJOR:-24}\"" \
      "${SCRIPT_DIR}/codex-devbox.sh"
}

summarizes_failed_commands() {
  local long_command summary

  long_command="$(printf 'x%.0s' {1..300})"
  summary="$(summarize_command "${long_command}"$'\nshould-not-appear')"
  ((${#summary} == 240)) &&
    [[ "$summary" == *... ]] &&
    [[ "$summary" != *should-not-appear* ]]
}

selects_latest_amd64_template() {
  local available

  available=$'system ubuntu-24.04-standard_24.04-1_amd64.tar.zst\n'
  available+=$'system ubuntu-24.04-standard_24.04-3_arm64.tar.zst\n'
  available+=$'system ubuntu-22.04-standard_22.04-9_amd64.tar.zst\n'
  available+='system ubuntu-24.04-standard_24.04-2_amd64.tar.zst'

  [[ "$(latest_ubuntu_template <<<"$available")" == \
    "ubuntu-24.04-standard_24.04-2_amd64.tar.zst" ]]
}

embedded_provisioner() {
  awk '
    /^    bash -s <<'\''INNER'\''$/ { inside=1; next }
    /^INNER$/ { inside=0 }
    inside
  ' "${SCRIPT_DIR}/codex-devbox.sh"
}

validates_embedded_provisioner_syntax() {
  bash -n <(embedded_provisioner)
}

provisioner_uses_safe_user_context() {
  local provisioner

  provisioner="$(embedded_provisioner)"

  grep -Fq 'run_as_dev() {' <<<"$provisioner" &&
    grep -Fq "cd \"\$HOME\"" <<<"$provisioner" &&
    [[ "$(grep -Fc "sudo -u \"\$DEV_USER\"" <<<"$provisioner")" -eq 1 ]] &&
    grep -Fq 'run_as_dev env ' <<<"$provisioner" &&
    grep -Fq 'run_as_dev git lfs install --skip-repo' <<<"$provisioner" &&
    grep -Fq "run_as_dev \"\${DEV_HOME}/.local/bin/codex\" --version" \
      <<<"$provisioner" &&
    grep -Fq 'Installierte Codex-Version entspricht nicht' \
      <<<"$provisioner"
}

provisioner_reports_inner_failures() {
  local provisioner

  provisioner="$(embedded_provisioner)"
  grep -Fq 'trap on_inner_error ERR' <<<"$provisioner" &&
    grep -Fq "command=\"\${command%%" <<<"$provisioner" &&
    grep -Fq "printf 'Teilschritt: %s\\n'" <<<"$provisioner"
}

provisioner_uses_portable_locale() {
  grep -Fq 'LANG=C.UTF-8 ' "${SCRIPT_DIR}/codex-devbox.sh" &&
    grep -Fq 'LC_ALL=C.UTF-8 ' "${SCRIPT_DIR}/codex-devbox.sh"
}

provisioner_configures_fd_for_non_login_shells() {
  local provisioner path_line fd_check_line

  provisioner="$(embedded_provisioner)"
  path_line="$(
    grep -nF \
      'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
      <<<"$provisioner" |
      cut -d: -f1
  )"
  fd_check_line="$(
    grep -nFx 'command -v fd' <<<"$provisioner" |
      cut -d: -f1
  )"

  [[ "$path_line" =~ ^[0-9]+$ ]] &&
    [[ "$fd_check_line" =~ ^[0-9]+$ ]] &&
    ((path_line < fd_check_line)) &&
    grep -Fq "fd_binary=\"\$(command -v fdfind || true)\"" \
      <<<"$provisioner" &&
    grep -Fq "[[ -z \"\$fd_binary\" && -x /usr/lib/cargo/bin/fd ]]" \
      <<<"$provisioner" &&
    grep -Fq "ln -sfn -- \"\$fd_binary\" /usr/local/bin/fd" \
      <<<"$provisioner" &&
    grep -Fq '[[ -x /usr/local/bin/fd ]]' <<<"$provisioner"
}

provisioner_prepares_sshd_runtime() {
  local provisioner runtime_line validation_line

  provisioner="$(embedded_provisioner)"
  runtime_line="$(
    grep -nF 'install -d -m 0755 /run/sshd' <<<"$provisioner" |
      cut -d: -f1
  )"
  validation_line="$(
    grep -nF '/usr/sbin/sshd -t' <<<"$provisioner" |
      head -n 1 |
      cut -d: -f1
  )"

  [[ "$runtime_line" =~ ^[0-9]+$ ]] &&
    [[ "$validation_line" =~ ^[0-9]+$ ]] &&
    ((runtime_line < validation_line))
}

provisioner_verifies_effective_ssh_security() {
  local provisioner

  provisioner="$(embedded_provisioner)"
  grep -Fq '/etc/ssh/sshd_config.d/00-codex-devbox.conf' \
    <<<"$provisioner" &&
    grep -Fq '/usr/sbin/sshd -T ' <<<"$provisioner" &&
    grep -Fq 'assert_sshd_setting passwordauthentication no' \
      <<<"$provisioner" &&
    grep -Fq 'assert_sshd_setting authenticationmethods publickey' \
      <<<"$provisioner" &&
    grep -Fq "assert_sshd_setting allowagentforwarding \"\$ALLOW_AGENT_FORWARDING\"" \
      <<<"$provisioner" &&
    grep -Fq 'systemctl is-active --quiet ssh.service' <<<"$provisioner"
}

provisioner_checks_critical_endpoints() {
  grep -Fq 'archive.ubuntu.com' "${SCRIPT_DIR}/codex-devbox.sh" &&
    grep -Fq 'security.ubuntu.com' "${SCRIPT_DIR}/codex-devbox.sh" &&
    grep -Fq 'deb.nodesource.com' "${SCRIPT_DIR}/codex-devbox.sh" &&
    grep -Fq 'chatgpt.com' "${SCRIPT_DIR}/codex-devbox.sh"
}

run_test "valid IPv4 addresses" accepts_valid_ipv4
run_test "invalid IPv4 addresses" rejects_invalid_ipv4
run_test "IPv4 CIDR validation" validates_ipv4_cidr
run_test "static IPv4 network semantics" validates_static_network_semantics
run_test "IPv4 integer conversion" converts_ipv4_to_integer
run_test "Proxmox versions are parsed" parses_supported_pve_versions
run_test "real SSH public key" validates_real_ssh_key
run_test "malformed SSH public keys" rejects_malformed_ssh_keys
run_test "valid installation settings" accepts_valid_settings
run_test "root user is rejected" rejects_root_user
run_test "invalid static network is rejected" rejects_invalid_static_network
run_test "usable static network is accepted" accepts_usable_static_network
run_test "unusable static network is rejected" rejects_unusable_static_network
run_test "undersized resources are rejected" rejects_undersized_resources
run_test "VMID is checked cluster-wide" checks_vmid_cluster_wide
run_test "occupied VMID is rejected" rejects_occupied_vmid
run_test "insufficient storage is rejected" rejects_missing_storage_capacity
run_test "unknown CLI option returns exit code 2" rejects_unknown_option
run_test "version and LTS default are current" reports_current_version_and_lts_default
run_test "failed commands are summarized" summarizes_failed_commands
run_test "latest amd64 template is selected" selects_latest_amd64_template
run_test "embedded provisioner syntax" validates_embedded_provisioner_syntax
run_test "provisioner uses safe user context" provisioner_uses_safe_user_context
run_test "provisioner reports inner failures" provisioner_reports_inner_failures
run_test "provisioner uses portable locale" provisioner_uses_portable_locale
run_test "provisioner configures fd for non-login shells" provisioner_configures_fd_for_non_login_shells
run_test "provisioner prepares sshd runtime" provisioner_prepares_sshd_runtime
run_test "provisioner verifies SSH security" provisioner_verifies_effective_ssh_security
run_test "provisioner checks critical endpoints" provisioner_checks_critical_endpoints

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
