#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
readonly INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"
readonly MANAGER_SOURCE="${PROJECT_ROOT}/bin/devbox.sh"
readonly LIB_COMMON="${PROJECT_ROOT}/lib/common.sh"
readonly LIB_USER="${PROJECT_ROOT}/lib/user.sh"
readonly FEATURE_BASE="${PROJECT_ROOT}/features/base.sh"
readonly FEATURE_NODE="${PROJECT_ROOT}/features/node.sh"
readonly FEATURE_POSTGRES="${PROJECT_ROOT}/features/postgres.sh"
readonly FEATURE_AGENTS="${PROJECT_ROOT}/features/agents.sh"
readonly FEATURE_HAPPY="${PROJECT_ROOT}/features/happy.sh"
readonly FEATURE_TOOLING="${PROJECT_ROOT}/features/tooling.sh"
readonly FEATURE_ELIXIR="${PROJECT_ROOT}/features/elixir.sh"
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
  # The manager used to be a heredoc embedded in install.sh; it now lives in
  # its own source file (bin/devbox.sh) that install.sh downloads at install
  # time and writes verbatim to /usr/local/bin/devbox, so extraction is just
  # a copy.
  cp "$MANAGER_SOURCE" "$MANAGER"
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
readonly NORM_LIB_USER="${TEST_TMP}/lib_user.normalized"
readonly NORM_FEATURE_BASE="${TEST_TMP}/feature_base.normalized"
readonly NORM_FEATURE_POSTGRES="${TEST_TMP}/feature_postgres.normalized"
readonly NORM_FEATURE_HAPPY="${TEST_TMP}/feature_happy.normalized"
readonly NORM_FEATURE_TOOLING="${TEST_TMP}/feature_tooling.normalized"
readonly NORM_FEATURE_ELIXIR="${TEST_TMP}/feature_elixir.normalized"

scripts_have_valid_syntax() {
  bash -n \
    "$INSTALL_SCRIPT" \
    "$MANAGER" \
    "$LIB_COMMON" \
    "$LIB_USER" \
    "$FEATURE_BASE" \
    "$FEATURE_NODE" \
    "$FEATURE_POSTGRES" \
    "$FEATURE_AGENTS" \
    "$FEATURE_HAPPY" \
    "$FEATURE_TOOLING" \
    "$FEATURE_ELIXIR"
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
    [[ -f "${PROJECT_ROOT}/bin/devbox.sh" ]] &&
    [[ -f "${PROJECT_ROOT}/README.md" ]] &&
    [[ -f "${PROJECT_ROOT}/tests/test-devbox.sh" ]] &&
    grep -Fq '${repo_url%/}/${ref}/devbox/install.sh' "$MANAGER" &&
    ! grep -Eq 'Scripts/(master|\$\{branch\})/install\.sh' "$MANAGER"
}

# install.sh and the manager it downloads must always come from the same
# commit/branch, or a mid-flight update could mix an old manager with a new
# installer (or vice versa). Both must therefore key off the same ref
# mechanism (DEVBOX_REPO_URL/DEVBOX_REF), not independent hardcoded values.
install_script_fetches_matching_manager_version() {
  grep -Fq 'DEVBOX_REF="${DEVBOX_REF:-master}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'fetch_devbox_module() {' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEVBOX_REPO_URL%/}/${DEVBOX_REF}/devbox/${module_path}"' "$NORM_INSTALL" &&
    grep -Fq 'fetch_devbox_module "bin/devbox.sh" "/usr/local/bin/devbox"' "$INSTALL_SCRIPT"
}

# lib/*.sh and features/*.sh hold operational helpers and installation
# phases that are only needed after the bootstrap preflight has already run;
# none of them may be defined inline in install.sh anymore, only downloaded
# and sourced in a loop, and the bootstrap chain itself (root/OS/network
# checks, curl_with_retry, fetch_devbox_module) must stay inline since it's
# needed to fetch these files in the first place.
install_script_loads_all_modules_after_bootstrap() {
  local module

  for module in \
    lib/common.sh \
    lib/user.sh \
    features/base.sh \
    features/node.sh \
    features/postgres.sh \
    features/agents.sh \
    features/happy.sh \
    features/tooling.sh \
    features/elixir.sh; do

    grep -Fq "$module" "$NORM_INSTALL" || return 1
  done

  grep -Fq 'fetch_devbox_module "$devbox_module" "$devbox_module_tmp"' "$INSTALL_SCRIPT" &&
    grep -Fq 'source "$devbox_module_tmp"' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'verify_checksum() {' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'run_as_dev() (' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'create_developer_user() {' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'install_erlang() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'verify_checksum() {' "$LIB_COMMON" &&
    grep -Fq 'run_as_dev() (' "$LIB_COMMON" &&
    grep -Fq 'create_developer_user() {' "$LIB_USER" &&
    grep -Fq 'install_erlang() {' "$FEATURE_ELIXIR"
}

# P1.2: DEVBOX_PROFILE (default/minimal) and DEVBOX_FEATURES (explicit
# override) resolve to the set of optional features (elixir, postgres) an
# install actually runs. Extract just that block and exercise it in
# isolation under different env combinations, without running the rest of
# install.sh.
extract_feature_resolution_block() {
  sed -n '/^DEVBOX_ALL_OPTIONAL_FEATURES=/,/^msg_ok "DevBox profile:/p' "$INSTALL_SCRIPT"
}

feature_resolution_selects_features_from_profile_and_override() {
  local block
  block="$(extract_feature_resolution_block)"

  [[ -n "$block" ]] || return 1

  # default profile: both optional features on.
  [[ "$(
    bash -c '
      msg_error() { echo "ERROR: $*" >&2; exit 1; }
      msg_ok() { :; }
      '"$block"'
      echo "$devbox_selected_features"
    '
  )" == "elixir postgres" ]] &&
    # minimal profile: no optional features.
    [[ "$(
      bash -c '
        msg_error() { echo "ERROR: $*" >&2; exit 1; }
        msg_ok() { :; }
        DEVBOX_PROFILE=minimal
        '"$block"'
        echo "$devbox_selected_features"
      '
    )" == "" ]] &&
    # explicit empty override: no optional features, even on default profile.
    [[ "$(
      bash -c '
        msg_error() { echo "ERROR: $*" >&2; exit 1; }
        msg_ok() { :; }
        DEVBOX_FEATURES=""
        '"$block"'
        echo "$devbox_selected_features"
      '
    )" == "" ]] &&
    # explicit override: only the named feature, regardless of profile.
    [[ "$(
      bash -c '
        msg_error() { echo "ERROR: $*" >&2; exit 1; }
        msg_ok() { :; }
        DEVBOX_PROFILE=minimal
        DEVBOX_FEATURES="postgres"
        '"$block"'
        echo "$devbox_selected_features"
      '
    )" == "postgres" ]] &&
    # unknown feature: rejected.
    ! bash -c '
      msg_error() { echo "ERROR: $*" >&2; exit 1; }
      msg_ok() { :; }
      DEVBOX_FEATURES="not-a-real-feature"
      '"$block"'
    ' >/dev/null 2>&1 &&
    # unknown profile: rejected.
    ! bash -c '
      msg_error() { echo "ERROR: $*" >&2; exit 1; }
      msg_ok() { :; }
      DEVBOX_PROFILE="not-a-real-profile"
      '"$block"'
    ' >/dev/null 2>&1
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
  grep -Fq 'OTP_ROOT="/opt/devbox/otp"' "$FEATURE_ELIXIR" &&
    grep -Fq 'ELIXIR_ROOT="/opt/devbox/elixir"' "$FEATURE_ELIXIR" &&
    grep -Fq './Install -minimal "$OTP_ROOT"' "$NORM_FEATURE_ELIXIR" &&
    grep -Fq 'ln -sfn "${OTP_ROOT}/bin/${otp_bin}" "/usr/local/bin/${otp_bin}"' \
      "$NORM_FEATURE_ELIXIR" &&
    grep -Fq 'ln -sfn "${ELIXIR_ROOT}/bin/${elixir_bin}" "/usr/local/bin/${elixir_bin}"' \
      "$NORM_FEATURE_ELIXIR" &&
    # mise must never be told to provide erlang or elixir ...
    ! grep -Eq 'mise[^\n]*(use|exec|reshim)[^\n]*(erlang|elixir)' "$FEATURE_TOOLING" "$FEATURE_ELIXIR" &&
    ! grep -Eq 'MISE_ERLANG|erlang@|elixir@' "$FEATURE_TOOLING" "$FEATURE_ELIXIR" &&
    # ... and its shims must stay off the PATH the installer hands to dev.
    ! grep -Fq 'mise/shims:' "$FEATURE_TOOLING"
}

# mise stays available for other languages a project may need.
mise_is_available_as_a_developer_tool() {
  grep -Fq 'curl_with_retry "https://mise.run" "$mise_installer"' "$NORM_FEATURE_TOOLING" &&
    grep -Fq 'MISE_INSTALL_PATH="${DEV_HOME}/.local/bin/mise"' "$FEATURE_TOOLING"
}

# OTP 28 crashed on boot in this container class; 29.0.5 is the verified one
# (confirmed running cleanly on this very devbox).
erlang_is_pinned_to_a_verified_release() {
  grep -Fq 'ERLANG_VERSION="${ERLANG_VERSION:-29.0.5}"' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'ERLANG_VERSION="${ERLANG_VERSION:-28' "$INSTALL_SCRIPT"
}

erlang_comes_from_the_precompiled_ubuntu_build() {
  grep -Fq 'builds.hex.pm/builds/otp/${otp_arch}/${otp_os}/OTP-${ERLANG_VERSION}.tar.gz' \
    "$FEATURE_ELIXIR" &&
    grep -Fq 'otp_arch="$(dpkg --print-architecture)"' "$FEATURE_ELIXIR" &&
    ! grep -Fq 'KERL_CONFIGURE_OPTIONS' "$FEATURE_ELIXIR" &&
    grep -Fq "run_as_dev erl -noshell -eval 'halt(0).'" "$NORM_FEATURE_ELIXIR"
}

# Erlang writes ~/.erlang.cookie when the kernel application starts; an
# unwritable HOME took the whole runtime down during the original failure.
erlang_cookie_is_provisioned() {
  grep -Fq '"${DEV_HOME}/.erlang.cookie"' "$FEATURE_ELIXIR" &&
    grep -Fq 'chmod 0400 "${DEV_HOME}/.erlang.cookie"' "$NORM_FEATURE_ELIXIR" &&
    grep -Fq 'HOME="$DEV_HOME"' "$LIB_COMMON"
}

installer_requires_ubuntu() {
  grep -Fq 'require_supported_os() {' "$INSTALL_SCRIPT" &&
    grep -Fxq 'require_supported_os' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'require_debian_like' "$INSTALL_SCRIPT" &&
    grep -Fq 'ubuntu-24.04 | ubuntu-22.04 | ubuntu-20.04)' "$INSTALL_SCRIPT" &&
    grep -Fq 'add-apt-repository -y universe' "$NORM_FEATURE_BASE"
}

elixir_is_pinned_to_the_erlang_otp_major() {
  # Elixir releases are published per OTP major, so deriving the artifact from
  # ERLANG_VERSION keeps the pair from drifting apart on version bumps.
  grep -Fq 'ERLANG_OTP_MAJOR="${ERLANG_VERSION%%.*}"' "$FEATURE_ELIXIR" &&
    grep -Fq 'releases/download/v${ELIXIR_VERSION}/elixir-otp-${ERLANG_OTP_MAJOR}.zip' \
      "$FEATURE_ELIXIR"
}

claude_cli_is_installed() {
  local norm_feature_agents="${TEST_TMP}/feature_agents.normalized"
  normalize_continuations "$FEATURE_AGENTS" >"$norm_feature_agents"

  grep -Fq 'npm install --global "@anthropic-ai/claude-code@${CLAUDE_VERSION}"' "$norm_feature_agents" &&
    grep -Fq 'npm install --global "@openai/codex@${CODEX_VERSION}"' "$norm_feature_agents" &&
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

# P1.3: update_devbox() takes --check/--to/--branch flags, plus the
# backward-compatible bare-word shorthand for --branch, and main() passes it
# the full remaining argument vector (not just a single positional, which
# can't carry "--to v1.2.3").
update_command_supports_flags_and_positional_branch() {
  grep -Fq 'update_devbox() {' "$MANAGER" &&
    grep -Fq 'readonly DEFAULT_GITHUB_REPO="c4kingpin/Scripts"' "$MANAGER" &&
    grep -Fq -- '--check)' "$MANAGER" &&
    grep -Fq -- '--to)' "$MANAGER" &&
    grep -Fq -- '--branch)' "$MANAGER" &&
    grep -Fq 'update:*)' "$MANAGER" &&
    grep -Fq 'update_devbox "${@:2}"' "$MANAGER" &&
    grep -Fq 'rollback:)' "$MANAGER" &&
    grep -Fq 'rollback_devbox' "$MANAGER" &&
    grep -Fq 'update [--check] [--to TAG] [--branch NAME]' "$MANAGER"
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
echo "DEVBOX_REF=${DEVBOX_REF:-<unset>}"
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
    grep -Fq "Downloading installer from branch 'feature-branch'" "$output_file" &&
    # The re-exec'd installer must fetch its own lib/features modules from
    # the same ref it was itself downloaded from (P1.1 rule), not silently
    # fall back to install.sh's own DEVBOX_REF default.
    grep -Fq "DEVBOX_REF=feature-branch" "$output_file"
}

update_to_flag_targets_a_release_tag() {
  local fake_repo="${TEST_TMP}/fake-repo-release"
  local output_file="${TEST_TMP}/update-release-output.log"
  local bin_dir="${TEST_TMP}/bin-release"
  local manager_functions="${TEST_TMP}/manager-functions-release.sh"

  mkdir -p "$fake_repo" "$bin_dir"
  cat <<'EOF' >"${fake_repo}/install.sh"
#!/usr/bin/env bash
echo "ran fake installer"
echo "DEVBOX_REF=${DEVBOX_REF:-<unset>}"
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
*/v1.2.3/devbox/install.sh)
  cp "${fake_repo}/install.sh" "\$out"
  ;;
*)
  exit 22
  ;;
esac
EOF
  chmod 0755 "${bin_dir}/curl"

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
    update_devbox --to v1.2.3
  ) >"$output_file" 2>&1 || true

  grep -Fq "ran fake installer" "$output_file" &&
    grep -Fq "Downloading installer from release 'v1.2.3'" "$output_file" &&
    grep -Fq "DEVBOX_REF=v1.2.3" "$output_file"
}

update_check_reports_without_installing() {
  local output_file="${TEST_TMP}/update-check-output.log"
  local bin_dir="${TEST_TMP}/bin-check"
  local manager_functions="${TEST_TMP}/manager-functions-check.sh"

  mkdir -p "$bin_dir"

  cat <<'EOF' >"${bin_dir}/curl"
#!/usr/bin/env bash
url="${!#}"
case "$url" in
*/releases/latest)
  echo '{"tag_name": "v99.0.0"}'
  ;;
*)
  echo "unexpected curl invocation: $url" >&2
  exit 22
  ;;
esac
EOF
  chmod 0755 "${bin_dir}/curl"

  head -n -1 "$MANAGER" >"$manager_functions"

  (
    set -Eeuo pipefail
    PATH="${bin_dir}:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$manager_functions"
    # shellcheck disable=SC2317,SC2329 # invoked indirectly by update_devbox below
    require_root() { :; }
    update_devbox --check
  ) >"$output_file" 2>&1

  grep -Fq "Update available: 1.1.1 -> v99.0.0" "$output_file" &&
    ! grep -Fq "Downloading installer" "$output_file"
}

update_check_handles_no_releases_gracefully() {
  local output_file="${TEST_TMP}/update-check-none-output.log"
  local bin_dir="${TEST_TMP}/bin-check-none"
  local manager_functions="${TEST_TMP}/manager-functions-check-none.sh"

  mkdir -p "$bin_dir"

  cat <<'EOF' >"${bin_dir}/curl"
#!/usr/bin/env bash
exit 22
EOF
  chmod 0755 "${bin_dir}/curl"

  head -n -1 "$MANAGER" >"$manager_functions"

  (
    set -Eeuo pipefail
    PATH="${bin_dir}:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$manager_functions"
    # shellcheck disable=SC2317,SC2329 # invoked indirectly by update_devbox below
    require_root() { :; }
    update_devbox --check
  ) >"$output_file" 2>&1

  grep -Fq "No published releases yet" "$output_file"
}

rollback_reruns_previous_ref() {
  local output_file="${TEST_TMP}/rollback-output.log"
  local rollback_fn="${TEST_TMP}/rollback-fn.sh"
  local previous_ref_file="${TEST_TMP}/previous-ref"
  local previous_version_file="${TEST_TMP}/previous-version"

  sed -n '/^rollback_devbox() {/,/^}/p' "$MANAGER" >"$rollback_fn"

  printf 'release:v0.9.0\n' >"$previous_ref_file"
  printf '1.0.0\n' >"$previous_version_file"

  (
    set -Eeuo pipefail
    # shellcheck disable=SC2034 # read by rollback_devbox below (sourced at runtime)
    PREVIOUS_REF_FILE="$previous_ref_file"
    # shellcheck disable=SC2034 # read by rollback_devbox below (sourced at runtime)
    PREVIOUS_VERSION_FILE="$previous_version_file"
    # shellcheck disable=SC2034 # read by rollback_devbox below (sourced at runtime)
    DEVBOX_VERSION="1.0.0"
    # shellcheck disable=SC2317,SC2329 # invoked by rollback_devbox below
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # invoked by rollback_devbox below
    die() {
      echo "DIE: $*" >&2
      exit 1
    }
    # shellcheck disable=SC2317,SC2329 # invoked by rollback_devbox below
    info() { echo "INFO: $*"; }
    # migration is exercised by its own test; this one is only about
    # rollback_devbox() reading the (already-migrated) root-state files.
    # shellcheck disable=SC2317,SC2329 # invoked by rollback_devbox below
    migrate_legacy_previous_update_state() { :; }
    # shellcheck disable=SC2317,SC2329 # invoked by rollback_devbox below
    update_devbox() { echo "CALLED update_devbox: $*"; }
    # shellcheck source=/dev/null
    source "$rollback_fn"
    rollback_devbox
  ) >"$output_file" 2>&1

  grep -Fq "CALLED update_devbox: --to v0.9.0" "$output_file"
}

# P0.1: dev must control OS package installs through a validated DevBox
# command instead of a generic passwordless apt/apt-get/dpkg grant.
no_generic_passwordless_package_management() {
  ! grep -Eq 'NOPASSWD:.*(/usr/bin/apt-get|/usr/bin/apt\b|/usr/bin/dpkg)' \
    "$INSTALL_SCRIPT" &&
    grep -Fq \
      '${DEV_USER} ALL=(root) NOPASSWD: /usr/local/bin/devbox packages install *' \
      "$NORM_INSTALL"
}

package_name_validation_accepts_and_rejects_expected_input() {
  bash -c '
    set -Eeuo pipefail
    source <(head -n -1 "$1")

    accept=(imagemagick libvips ffmpeg-x sqlite3 a pkg-config redis-tools)
    reject=("../evil" "-o" "--force" "pkg;rm -rf /" "UPPER" "" "./foo.deb" "pkg=1.0")

    for pkg in "${accept[@]}"; do
      validate_package_name "$pkg" || exit 1
    done

    for pkg in "${reject[@]}"; do
      validate_package_name "$pkg" && exit 1
    done

    exit 0
  ' _ "$MANAGER"
}

packages_install_requires_root_and_at_least_one_package() {
  grep -Fq 'packages_install() {' "$MANAGER" &&
    grep -Fq 'require_root' "$NORM_MANAGER" &&
    grep -Fq 'Usage: devbox packages install <package...>' "$MANAGER" &&
    grep -Fq 'packages:install)' "$MANAGER" &&
    grep -Fq 'packages_install "${@:3}"' "$NORM_MANAGER" &&
    grep -Fq -- '-- "${packages[@]}"' "$NORM_MANAGER"
}

developer_user_is_least_privilege() {
  # SSH policy is scoped to a `Match User dev` block (not a global
  # AllowUsers directive), so administrative/root SSH access is never
  # touched by DevBox.
  grep -Fq 'useradd --create-home --user-group --shell /bin/bash' \
    "$NORM_LIB_USER" &&
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
  python3 - "$NORM_LIB_USER" <<'PY'
import pathlib
import re
import sys

install = pathlib.Path(sys.argv[1]).read_text()
match = re.search(
    r'if ! id "\$DEV_USER".*?\n(.*?)\n[ \t]*fi\n',
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
  local user_call_line
  local toolchain_call_line
  local permissions_root="${TEST_TMP}/permissions"

  # Each install -d entry is one argument per line ending in a backslash;
  # anchor on that trailing backslash so this only matches the entry that
  # actually creates the directory, not the migration guard that also names
  # the same path (on a line ending in "]]; then" instead).
  # shellcheck disable=SC1003
  config_line="$(grep -nF '"${DEV_HOME}/.config" \' "$LIB_USER" | head -n 1 | cut -d: -f1)"
  # shellcheck disable=SC1003
  state_line="$(grep -nF '"${DEV_HOME}/.config/devbox" \' "$LIB_USER" | head -n 1 | cut -d: -f1)"
  # The dev-user directories must exist before the toolchain install runs;
  # since that's now two separate sourced files, check the call order in
  # install.sh instead of a shared line-number space.
  user_call_line="$(grep -nE '^create_developer_user$' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"
  # install_erlang now runs inside an "if feature_enabled elixir" guard, so
  # it's indented rather than a bare top-level call.
  toolchain_call_line="$(grep -nE '^[[:space:]]*install_erlang$' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"

  grep -Fq 'run_as_dev test -w "$developer_dir"' "$NORM_LIB_USER" &&
    grep -Fq 'Developer directory is not writable:' "$LIB_USER" ||
    return 1

  [[ -n "$config_line" && -n "$state_line" && -n "$user_call_line" && -n "$toolchain_call_line" ]] &&
    ((config_line < state_line && user_call_line < toolchain_call_line)) &&
    grep -Fq '"${DEV_HOME}/.cache"' "$LIB_USER" &&
    grep -Fq '"${DEV_HOME}/.local"' "$LIB_USER" &&
    grep -Fq '"${DEV_HOME}/.local/bin"' "$LIB_USER" || return 1

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
    grep -Fq "SELECT 1 FROM pg_roles WHERE rolname = '\${PG_DB_USER}'" "$FEATURE_POSTGRES" &&
    grep -Fq "SELECT 1 FROM pg_database WHERE datname = '\${PG_DB_NAME}'" "$FEATURE_POSTGRES" &&
    grep -Fq "grep -q '^PGPASSWORD='" "$NORM_FEATURE_POSTGRES"
}

# Everything the old name owned must be carried over or removed; the state
# directory holds the only copy of the DB password and the OpenRouter key.
renaming_migrates_existing_installations() {
  grep -Fq 'mv "${DEV_HOME}/.config/codex-devbox" "${DEV_HOME}/.config/devbox"' \
    "$NORM_LIB_USER" &&
    grep -Fq '/usr/local/bin/codex-devbox' "$LIB_USER" &&
    grep -Fq '/etc/sudoers.d/90-codex-devbox' "$LIB_USER" &&
    grep -Fq '/etc/ssh/sshd_config.d/00-codex-devbox.conf' "$INSTALL_SCRIPT" &&
    grep -Fq '/etc/profile.d/codex-devbox.sh' "$LIB_USER" &&
    grep -Fq "s/# Codex Dev Box/# DevBox/" "$INSTALL_SCRIPT" &&
    grep -Eq 'Managed by \(devbox\|codex-devbox\) openrouter setup' "$MANAGER"
}

# The rename must not leave the old command, paths or env vars behind.
old_name_is_gone_from_the_active_surface() {
  ! grep -Fq 'CODEX_DEVBOX_REPO_URL' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'CODEX_AUTONOMY' "$INSTALL_SCRIPT" &&
    ! grep -Fq 'Usage: codex-devbox' "$MANAGER" &&
    grep -Fq 'Usage: devbox COMMAND' "$MANAGER" &&
    grep -Fq 'fetch_devbox_module "bin/devbox.sh" "/usr/local/bin/devbox"' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_REPO_URL' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_AUTONOMY' "$INSTALL_SCRIPT"
}

ssh_onboarding_distinguishes_key_directions() {
  grep -Fq 'Never copy a private key here.' "$MANAGER" &&
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
    grep -Fq 'devbox ssh setup' <<<"$output" &&
    grep -Fq 'devbox-happy-daemon.service' <<<"$output"
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
    grep -Fq 'update [--check] [--to TAG] [--branch NAME]' <<<"$output" &&
    grep -Fq 'rollback' <<<"$output"
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
    grep -Fq 'chmod 0600' "$NORM_FEATURE_POSTGRES" &&
    grep -Fq '"${DEV_HOME}/.pgpass"' "$FEATURE_POSTGRES" &&
    grep -Fq '"$PG_ENV_FILE"' "$FEATURE_POSTGRES" &&
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

# P0.2: no actively managed npm component may float on @latest.
managed_agent_clis_are_pinned_not_latest() {
  ! grep -Eq '(@openai/codex|@anthropic-ai/claude-code|[[:space:]]happy)@latest' \
    "$INSTALL_SCRIPT" "$FEATURE_AGENTS" "$FEATURE_HAPPY" &&
    grep -Fq '"@openai/codex@${CODEX_VERSION}"' "$FEATURE_AGENTS" &&
    grep -Fq '"@anthropic-ai/claude-code@${CLAUDE_VERSION}"' "$FEATURE_AGENTS" &&
    grep -Fq '"happy@${HAPPY_VERSION}"' "$FEATURE_HAPPY"
}

# install.sh must stay a single, standalone, curl-pipeable file, so it embeds
# its own defaults instead of sourcing versions.env at runtime. This keeps
# devbox/versions.env (the documented source of truth) from silently
# drifting away from what install.sh and the generated manager actually use.
versions_env_matches_embedded_defaults() {
  python3 - "$PROJECT_ROOT" "$MANAGER" <<'PY'
import pathlib
import re
import sys

project_root, manager_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
versions_env = (project_root / "versions.env").read_text()
install_sh = (project_root / "install.sh").read_text()
manager = manager_path.read_text()

manifest = dict(re.findall(r'^([A-Z_]+)="([^"]*)"$', versions_env, re.M))
expected_keys = {
    "DEVBOX_VERSION", "NODE_VERSION", "ERLANG_VERSION", "ELIXIR_VERSION",
    "PHOENIX_VERSION", "CODEX_VERSION", "CLAUDE_VERSION", "HAPPY_VERSION",
}
assert expected_keys <= manifest.keys(), manifest

for key, value in manifest.items():
    pattern = re.compile(
        rf'{key}="\$\{{{key}:-{re.escape(value)}\}}"'
    )
    assert pattern.search(install_sh), \
        f"install.sh default for {key} does not match versions.env ({value})"

# The generated manager embeds its own literal copies (NODE_VERSION becomes
# NODE_MAJOR there) for the `devbox version` command.
manager_expected = {
    "DEVBOX_VERSION": manifest["DEVBOX_VERSION"],
    "NODE_MAJOR": manifest["NODE_VERSION"],
    "ERLANG_VERSION": manifest["ERLANG_VERSION"],
    "ELIXIR_VERSION": manifest["ELIXIR_VERSION"],
    "PHOENIX_VERSION": manifest["PHOENIX_VERSION"],
    "CODEX_VERSION": manifest["CODEX_VERSION"],
    "CLAUDE_VERSION": manifest["CLAUDE_VERSION"],
    "HAPPY_VERSION": manifest["HAPPY_VERSION"],
}

for key, value in manager_expected.items():
    pattern = re.compile(rf'readonly {key}="{re.escape(value)}"')
    assert pattern.search(manager), \
        f"manager embedded value for {key} does not match versions.env ({value})"
PY
}

devbox_version_command_reports_the_manifest() {
  local output

  output="$("$MANAGER" version)"
  grep -Fq 'DevBox:' <<<"$output" &&
    grep -Fq 'Codex CLI:' <<<"$output" &&
    grep -Fq 'Claude Code:' <<<"$output" &&
    grep -Fq 'Happy:' <<<"$output" &&
    grep -Fq 'version:)' "$MANAGER" &&
    grep -Fq 'show_version' "$NORM_MANAGER"
}

# P0.3: versioned binary artifacts are verified against a known checksum
# before being unpacked; a missing or wrong checksum aborts the install.
downloaded_toolchain_artifacts_are_checksum_verified() {
  local otp_verify_line otp_extract_line

  grep -Fq 'verify_checksum() {' "$LIB_COMMON" &&
    grep -Fq 'Checksum mismatch for' "$LIB_COMMON" &&
    grep -Fq 'No known checksum for' "$LIB_COMMON" &&
    grep -Fq 'rm -f "$file"' "$LIB_COMMON" &&
    grep -Fq 'DEVBOX_CHECKSUMS["otp:${ERLANG_VERSION}:${otp_os}:${otp_arch}"]' \
      "$FEATURE_ELIXIR" &&
    grep -Fq 'DEVBOX_CHECKSUMS["elixir:${ELIXIR_VERSION}:${ERLANG_OTP_MAJOR}"]' \
      "$FEATURE_ELIXIR" ||
    return 1

  # Verified before the archive is extracted, not after.
  otp_verify_line="$(grep -n 'verify_checksum ' "$FEATURE_ELIXIR" | head -n1 | cut -d: -f1)"
  otp_extract_line="$(grep -n 'rm -rf "$OTP_ROOT"' "$FEATURE_ELIXIR" | head -n1 | cut -d: -f1)"

  [[ -n "$otp_verify_line" && -n "$otp_extract_line" ]] &&
    ((otp_verify_line < otp_extract_line))
}

# Every hash checked into checksums.env must actually be the one install.sh
# uses, or a checksum update to one file could silently stop being enforced.
checksums_env_matches_embedded_checksums() {
  python3 - "$PROJECT_ROOT" <<'PY'
import pathlib
import re
import sys

project_root = pathlib.Path(sys.argv[1])
checksums_env = (project_root / "checksums.env").read_text()
install_sh = (project_root / "install.sh").read_text()

hashes = re.findall(r'_SHA256="([0-9a-f]{64})"', checksums_env)
assert len(hashes) >= 5, hashes

for digest in hashes:
    assert digest in install_sh, f"checksum {digest} missing from install.sh"
PY
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

# P1.2: the postgres feature's package install moved out of base.sh's
# monolithic apt-get call into its own function, gated by feature selection.
postgres_package_is_a_separate_optional_feature() {
  # shellcheck disable=SC1003
  ! grep -Fq 'postgresql \' "$FEATURE_BASE" &&
    grep -Fq 'install_postgres_package() {' "$FEATURE_POSTGRES" &&
    grep -Fq 'if feature_enabled postgres; then' "$INSTALL_SCRIPT" &&
    grep -Fq 'if feature_enabled elixir; then' "$INSTALL_SCRIPT" &&
    grep -Fq 'install_postgres_package' "$INSTALL_SCRIPT" &&
    grep -Fq 'enable_postgresql_service' "$INSTALL_SCRIPT" &&
    grep -Fq 'configure_postgres_dev_access' "$INSTALL_SCRIPT"
}

# P1.2: validation must not hard-require tools that a minimal install never
# installed; the elixir/postgres checks are the only ones gated because
# node/agents/happy stay mandatory (see plan).
validation_skips_checks_for_disabled_features() {
  local validation_block
  validation_block="$(sed -n '/^msg_info "Validating Installation"/,/^msg_ok "Validated Installation"/p' "$INSTALL_SCRIPT")"

  grep -Fq 'if feature_enabled elixir; then' <<<"$validation_block" &&
    grep -Fq 'if feature_enabled postgres; then' <<<"$validation_block" &&
    grep -Fxq 'node --version' "$INSTALL_SCRIPT"
}

# P1.2/P1.4: install.sh must persist which optional features it actually
# installed, so bin/devbox.sh's doctor() (a separately-downloaded,
# self-contained file, see P1.1) can tell which checks apply. P1.4 moved
# this from user-state to root-state (ROOT_STATE_DIR), alongside the
# active version and install metadata.
install_script_records_devbox_state() {
  grep -Fq 'readonly ROOT_STATE_DIR="/var/lib/devbox"' "$INSTALL_SCRIPT" &&
    grep -Fq 'install -d -m 0755 "$ROOT_STATE_DIR"' "$NORM_INSTALL" &&
    grep -Fq 'printf '\''%s\n'\'' "$DEVBOX_VERSION" >"${ROOT_STATE_DIR}/version"' "$INSTALL_SCRIPT" &&
    grep -Fq 'printf '\''%s\n'\'' "$devbox_selected_features" >"${ROOT_STATE_DIR}/installed-features"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${ROOT_STATE_DIR}/install-state.json"' "$INSTALL_SCRIPT"
}

# The P1.2/P1.3 user-state files are migrated into root-state once, so an
# in-place `devbox update` on a box that already recorded a feature
# selection or a prior update under the old location doesn't lose it.
install_script_migrates_legacy_user_state_features() {
  grep -Fq 'if [[ -f "${DEV_HOME}/.config/devbox/features" &&' "$NORM_INSTALL" &&
    grep -Fq '! -f "${ROOT_STATE_DIR}/installed-features" ]]; then' "$NORM_INSTALL" &&
    grep -Fq 'mv "${DEV_HOME}/.config/devbox/features" "${ROOT_STATE_DIR}/installed-features"' "$NORM_INSTALL"
}

# P1.2: doctor() must read that state file and skip elixir/postgres checks
# when they weren't installed, but keep checking everything when the file
# is absent (installs from before this feature, or before P1.2 entirely).
doctor_is_feature_aware() {
  grep -Fq 'readonly FEATURES_FILE="${ROOT_STATE_DIR}/installed-features"' "$MANAGER" &&
    grep -Fq 'feature_was_installed() {' "$MANAGER" &&
    grep -Fq '[[ -r "$FEATURES_FILE" ]] || return 0' "$MANAGER" &&
    grep -Fq 'feature_was_installed elixir' "$MANAGER" &&
    grep -Fq 'feature_was_installed postgres' "$MANAGER"
}

# P1.4: doctor() checks that the root-state version file agrees with the
# manager's own embedded DEVBOX_VERSION, without hard-failing when the
# file is simply missing (installs from before P1.4). Extract just the
# check (not the whole doctor(), which needs a real dev user/toolchain)
# and exercise its three branches directly.
# P2.6: devbox workspace list/doctor are read-only helpers over the dev
# user's project directories. Strip "readonly" from the sourced copy so
# WORKSPACE_DIR can point at a temp fixture instead of the real
# /home/dev/workspace, same technique as the doctor --json test above.
workspace_list_and_doctor_report_project_health_read_only() {
  local ws_dir="${TEST_TMP}/workspace-fixture"
  local manager_functions="${TEST_TMP}/manager-functions-workspace.sh"
  local list_output doctor_git_output doctor_no_git_output doctor_missing_status=0

  mkdir -p "${ws_dir}/project-a" "${ws_dir}/project-b"
  git -C "${ws_dir}/project-a" init -q
  : >"${ws_dir}/project-a/.env"

  sed 's/^readonly //' "$MANAGER" | head -n -1 >"$manager_functions"

  list_output="$(
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      WORKSPACE_DIR="'"$ws_dir"'"
      require_dev() { :; }
      workspace_list
    '
  )"

  doctor_git_output="$(
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      WORKSPACE_DIR="'"$ws_dir"'"
      require_dev() { :; }
      workspace_doctor project-a
    ' 2>&1
  )"

  doctor_no_git_output="$(
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      WORKSPACE_DIR="'"$ws_dir"'"
      require_dev() { :; }
      workspace_doctor project-b
    ' 2>&1
  )"

  bash -c '
    # shellcheck source=/dev/null
    source "'"$manager_functions"'"
    WORKSPACE_DIR="'"$ws_dir"'"
    require_dev() { :; }
    workspace_doctor does-not-exist
  ' >/dev/null 2>&1 || doctor_missing_status=$?

  grep -Fq 'project-a' <<<"$list_output" &&
    grep -Fq 'project-b' <<<"$list_output" &&
    grep -Fq 'Git repository' <<<"$doctor_git_output" &&
    grep -Fq '.env present' <<<"$doctor_git_output" &&
    grep -Fq 'Not a Git repository' <<<"$doctor_no_git_output" &&
    grep -Fq '.env not present' <<<"$doctor_no_git_output" &&
    [[ "$doctor_missing_status" -ne 0 ]] &&
    # Read-only by construction: no command in workspace_doctor()/
    # workspace_list() ever mutates the project directory it inspects.
    ! sed -n '/^workspace_list() {/,/^workspace_doctor() {/p' "$MANAGER" \
      | grep -Eq 'git (commit|checkout|branch -[dD]|push|reset)|rm -rf' &&
    grep -Fq 'workspace:list)' "$MANAGER" &&
    grep -Fq 'workspace:doctor)' "$MANAGER"
}

doctor_checks_root_state_version() {
  local check_block
  check_block="$(sed -n '/if \[\[ -r "\$ROOT_VERSION_FILE" \]\]; then/,/^  fi$/p' "$MANAGER")"

  [[ -n "$check_block" ]] || return 1

  local root_version_file="${TEST_TMP}/root-version"
  local output_missing output_mismatch output_match

  output_missing="$(
    bash -c '
      ok() { echo "OK: $*"; }
      warn() { echo "WARN: $*"; }
      ROOT_VERSION_FILE="'"${TEST_TMP}"'/does-not-exist"
      ROOT_STATE_DIR="/var/lib/devbox"
      DEVBOX_VERSION="1.0.0"
      '"$check_block"'
    '
  )"

  printf '0.9.0\n' >"$root_version_file"
  output_mismatch="$(
    bash -c '
      ok() { echo "OK: $*"; }
      warn() { echo "WARN: $*"; }
      ROOT_VERSION_FILE="'"$root_version_file"'"
      ROOT_STATE_DIR="/var/lib/devbox"
      DEVBOX_VERSION="1.0.0"
      '"$check_block"'
    '
  )"

  printf '1.0.0\n' >"$root_version_file"
  output_match="$(
    bash -c '
      ok() { echo "OK: $*"; }
      warn() { echo "WARN: $*"; }
      ROOT_VERSION_FILE="'"$root_version_file"'"
      ROOT_STATE_DIR="/var/lib/devbox"
      DEVBOX_VERSION="1.0.0"
      '"$check_block"'
    '
  )"

  grep -Fq "No DevBox root state found" <<<"$output_missing" &&
    grep -Fq "does not match the running manager" <<<"$output_mismatch" &&
    grep -Fq "OK: DevBox root state (1.0.0)" <<<"$output_match"
}

# Issue #19: Happy is the remote-access layer, so it has to come back on its
# own after a reboot. Before this it was only ever started from the dev
# user's .bashrc, i.e. after somebody had already logged in interactively.
happy_daemon_starts_at_boot() {
  grep -Fq 'install_happy_daemon_service() {' "$FEATURE_HAPPY" &&
    grep -Fxq 'install_happy_daemon_service' "$INSTALL_SCRIPT" &&
    grep -Fq 'HAPPY_SERVICE="devbox-happy-daemon.service"' "$FEATURE_HAPPY" &&
    grep -Fq 'HAPPY_SERVICE_UNIT="/etc/systemd/system/${HAPPY_SERVICE}"' "$FEATURE_HAPPY" &&
    # Runs as dev with a dev-shaped HOME, only once the network is up.
    grep -Fxq 'User=${DEV_USER}' "$FEATURE_HAPPY" &&
    grep -Fxq 'Environment=HOME=${DEV_HOME}' "$FEATURE_HAPPY" &&
    grep -Fxq 'After=network-online.target' "$FEATURE_HAPPY" &&
    grep -Fxq 'Wants=network-online.target' "$FEATURE_HAPPY" &&
    grep -Fxq 'WantedBy=multi-user.target' "$FEATURE_HAPPY" &&
    # No aggressive restart loop on a box that cannot start the daemon.
    grep -Fxq 'Restart=no' "$FEATURE_HAPPY" &&
    grep -Fq 'systemctl daemon-reload' "$FEATURE_HAPPY" &&
    grep -Fq 'systemctl enable --now "$HAPPY_SERVICE"' "$NORM_FEATURE_HAPPY" &&
    grep -Fq 'systemctl is-enabled --quiet devbox-happy-daemon.service' "$NORM_INSTALL"
}

# The .bashrc logic stays as a fallback for boxes whose service is missing
# or disabled (issue #19 explicitly asks for it to be kept).
happy_bashrc_start_remains_as_fallback() {
  grep -Fq '# DevBox Happy' "$INSTALL_SCRIPT" &&
    grep -Fq 'HAPPY_DAEMON_CHECKED' "$INSTALL_SCRIPT" &&
    grep -Fq 'happy daemon start' "$INSTALL_SCRIPT"
}

extract_happy_daemon_start_script() {
  sed -n '/^  cat <<'\''EOF'\'' >"\$HAPPY_DAEMON_START_SCRIPT"$/,/^EOF$/p' \
    "$FEATURE_HAPPY" \
    | sed '1d;$d' \
    >"$1"

  [[ -s "$1" ]] || return 1

  chmod 0755 "$1"
}

# The guard is what keeps an unpaired DevBox from producing a failed unit,
# and what keeps a reboot from stomping on a daemon that is already running.
# Cheap enough to run for real against a fake HOME and a `happy` stub.
happy_daemon_guard_starts_only_a_paired_idle_daemon() {
  local guard="${TEST_TMP}/happy-daemon-start.sh"
  local stub_dir="${TEST_TMP}/happy-stub"
  local marker="${TEST_TMP}/happy-stub-calls"
  local fake_home

  extract_happy_daemon_start_script "$guard" || return 1

  mkdir -p "$stub_dir"
  cat <<EOF >"${stub_dir}/happy"
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$marker"
EOF
  chmod 0755 "${stub_dir}/happy"

  run_guard() {
    HOME="$1" \
      PATH="${stub_dir}:/usr/local/bin:/usr/bin:/bin" \
      "$guard" \
      >/dev/null 2>&1
  }

  # Unpaired box: no credentials at all.
  fake_home="${TEST_TMP}/home-unpaired"
  mkdir -p "${fake_home}/.happy"
  : >"$marker"
  run_guard "$fake_home" || return 1
  [[ ! -s "$marker" ]] || return 1

  # Credentials present but no machine registration.
  fake_home="${TEST_TMP}/home-unregistered"
  mkdir -p "${fake_home}/.happy"
  printf 'key\n' >"${fake_home}/.happy/access.key"
  printf '{}\n' >"${fake_home}/.happy/settings.json"
  : >"$marker"
  run_guard "$fake_home" || return 1
  [[ ! -s "$marker" ]] || return 1

  # Paired box, daemon not running (stale pid): start it.
  fake_home="${TEST_TMP}/home-paired-idle"
  mkdir -p "${fake_home}/.happy"
  printf 'key\n' >"${fake_home}/.happy/access.key"
  printf '{"machineId":"m1"}\n' >"${fake_home}/.happy/settings.json"
  printf '{"pid":999999999}\n' >"${fake_home}/.happy/daemon.state.json"
  : >"$marker"
  run_guard "$fake_home" || return 1
  grep -Fxq 'daemon start' "$marker" || return 1

  # Paired box, daemon already running: leave it alone.
  fake_home="${TEST_TMP}/home-paired-running"
  mkdir -p "${fake_home}/.happy"
  printf 'key\n' >"${fake_home}/.happy/access.key"
  printf '{"machineId":"m1"}\n' >"${fake_home}/.happy/settings.json"
  printf '{"pid":%s}\n' "$$" >"${fake_home}/.happy/daemon.state.json"
  : >"$marker"
  run_guard "$fake_home" || return 1
  [[ ! -s "$marker" ]] || return 1

  # Happy not installed at all: still a clean exit. A PATH holding nothing
  # but bash (needed by the script's own shebang) keeps a Happy that happens
  # to be installed on the test host out of the way.
  local no_happy_dir="${TEST_TMP}/no-happy"
  mkdir -p "$no_happy_dir"
  ln -sf "$(command -v bash)" "${no_happy_dir}/bash"

  fake_home="${TEST_TMP}/home-paired-idle"
  : >"$marker"
  HOME="$fake_home" \
    PATH="$no_happy_dir" \
    "$guard" \
    >/dev/null 2>&1 ||
    return 1

  [[ ! -s "$marker" ]]
}

# doctor/auth status have to surface a box that would silently lose remote
# access on the next reboot (service missing, disabled or failed).
doctor_checks_happy_daemon_service() {
  grep -Fq 'readonly HAPPY_SERVICE="devbox-happy-daemon.service"' "$MANAGER" &&
    grep -Fq 'happy_daemon_service_is_installed() {' "$MANAGER" &&
    grep -Fq 'happy_daemon_service_is_enabled() {' "$MANAGER" &&
    grep -Fq 'systemctl is-enabled --quiet "$HAPPY_SERVICE"' "$NORM_MANAGER" &&
    grep -Fq 'systemctl is-failed --quiet "$HAPPY_SERVICE"' "$NORM_MANAGER" &&
    grep -Fq 'is not installed; Happy only starts from an interactive dev shell' "$MANAGER"
}

extract_manager
normalize_continuations "$INSTALL_SCRIPT" >"$NORM_INSTALL"
normalize_continuations "$MANAGER" >"$NORM_MANAGER"
normalize_continuations "$LIB_USER" >"$NORM_LIB_USER"
normalize_continuations "$FEATURE_BASE" >"$NORM_FEATURE_BASE"
normalize_continuations "$FEATURE_POSTGRES" >"$NORM_FEATURE_POSTGRES"
normalize_continuations "$FEATURE_HAPPY" >"$NORM_FEATURE_HAPPY"
normalize_continuations "$FEATURE_TOOLING" >"$NORM_FEATURE_TOOLING"
normalize_continuations "$FEATURE_ELIXIR" >"$NORM_FEATURE_ELIXIR"

run_test "Bash syntax" scripts_have_valid_syntax
run_test "standalone, no Proxmox/community-scripts framework" standalone_no_proxmox_framework
run_test "standalone preflight checks" install_script_runs_standalone_preflight
run_test "curl-pipeable from master" installer_curl_pipeable_from_master
run_test "project is self-contained under devbox/" project_is_self_contained
run_test "install.sh fetches a version-matched manager" install_script_fetches_matching_manager_version
run_test "install.sh loads all modules after bootstrap" install_script_loads_all_modules_after_bootstrap
run_test "feature resolution selects features from profile and override" feature_resolution_selects_features_from_profile_and_override
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
run_test "update command supports flags and positional branch" update_command_supports_flags_and_positional_branch
run_test "update downloads and reruns installer" update_downloads_and_reruns_installer
run_test "update honors the requested branch" update_branch_argument_is_honored
run_test "update --to targets a release tag" update_to_flag_targets_a_release_tag
run_test "update --check reports without installing" update_check_reports_without_installing
run_test "update --check handles no releases gracefully" update_check_handles_no_releases_gracefully
run_test "rollback reruns the previous ref" rollback_reruns_previous_ref
run_test "no generic passwordless package management" no_generic_passwordless_package_management
run_test "package name validation accepts/rejects expected input" package_name_validation_accepts_and_rejects_expected_input
run_test "packages install requires root and a package" packages_install_requires_root_and_at_least_one_package
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
run_test "managed agent CLIs are pinned, not @latest" managed_agent_clis_are_pinned_not_latest
run_test "versions.env matches embedded defaults" versions_env_matches_embedded_defaults
run_test "devbox version reports the manifest" devbox_version_command_reports_the_manifest
run_test "toolchain artifacts are checksum-verified" downloaded_toolchain_artifacts_are_checksum_verified
run_test "checksums.env matches embedded checksums" checksums_env_matches_embedded_checksums
run_test "complete stack validation" installer_validates_complete_stack
run_test "postgres package is a separate optional feature" postgres_package_is_a_separate_optional_feature
run_test "validation skips checks for disabled features" validation_skips_checks_for_disabled_features
run_test "install.sh records DevBox state" install_script_records_devbox_state
run_test "install.sh migrates legacy user-state features" install_script_migrates_legacy_user_state_features
run_test "doctor is feature-aware" doctor_is_feature_aware
run_test "workspace list/doctor report project health read-only" workspace_list_and_doctor_report_project_health_read_only
run_test "doctor checks root state version" doctor_checks_root_state_version
run_test "Happy daemon starts at boot" happy_daemon_starts_at_boot
run_test "Happy .bashrc start remains a fallback" happy_bashrc_start_remains_as_fallback
run_test "Happy boot guard only starts a paired, idle daemon" happy_daemon_guard_starts_only_a_paired_idle_daemon
run_test "doctor checks the Happy daemon service" doctor_checks_happy_daemon_service

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
