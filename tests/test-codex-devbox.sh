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

validates_embedded_provisioner_syntax() {
  bash -n <(
    awk '
      /^    bash -s <<'\''INNER'\''$/ { inside=1; next }
      /^INNER$/ { inside=0 }
      inside
    ' "${SCRIPT_DIR}/codex-devbox.sh"
  )
}

run_test "valid IPv4 addresses" accepts_valid_ipv4
run_test "invalid IPv4 addresses" rejects_invalid_ipv4
run_test "IPv4 CIDR validation" validates_ipv4_cidr
run_test "real SSH public key" validates_real_ssh_key
run_test "malformed SSH public keys" rejects_malformed_ssh_keys
run_test "valid installation settings" accepts_valid_settings
run_test "root user is rejected" rejects_root_user
run_test "invalid static network is rejected" rejects_invalid_static_network
run_test "insufficient storage is rejected" rejects_missing_storage_capacity
run_test "unknown CLI option returns exit code 2" rejects_unknown_option
run_test "embedded provisioner syntax" validates_embedded_provisioner_syntax

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
