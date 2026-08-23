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
readonly FEATURE_REDIS="${PROJECT_ROOT}/features/redis.sh"
readonly FEATURE_AGENTS="${PROJECT_ROOT}/features/agents.sh"
readonly FEATURE_HAPPY="${PROJECT_ROOT}/features/happy.sh"
readonly FEATURE_KISUKE="${PROJECT_ROOT}/features/kisuke.sh"
readonly FEATURE_MULTICA="${PROJECT_ROOT}/features/multica.sh"
readonly FEATURE_AGENT_NOTIFY="${PROJECT_ROOT}/features/agent-notify.sh"
readonly FEATURE_TOOLING="${PROJECT_ROOT}/features/tooling.sh"
readonly FEATURE_ELIXIR="${PROJECT_ROOT}/features/elixir.sh"
readonly LXC_INTEGRATION_TEST="${PROJECT_ROOT}/tests/lxc-integration-test.sh"
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
readonly NORM_FEATURE_KISUKE="${TEST_TMP}/feature_kisuke.normalized"
readonly NORM_FEATURE_AGENT_NOTIFY="${TEST_TMP}/feature_agent_notify.normalized"
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
    "$FEATURE_KISUKE" \
    "$FEATURE_MULTICA" \
    "$FEATURE_AGENT_NOTIFY" \
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
# Remote-provider modules (features/happy.sh, features/kisuke.sh) are no
# longer literal entries in this list - they're generated from
# DEVBOX_REMOTE_PROVIDERS (see the "Neuen Remote-Provider hinzufügen" module
# contract in devbox/README.md), so a new provider only needs an entry in
# that registry to be fetched here.
install_script_loads_all_modules_after_bootstrap() {
  local module

  for module in \
    lib/common.sh \
    lib/user.sh \
    features/base.sh \
    features/node.sh \
    features/postgres.sh \
    features/agents.sh \
    features/agent-notify.sh \
    features/tooling.sh \
    features/elixir.sh; do

    grep -Fq "$module" "$NORM_INSTALL" || return 1
  done

  grep -Fq 'readonly DEVBOX_REMOTE_PROVIDERS="happy kisuke multica"' "$INSTALL_SCRIPT" &&
    grep -Fq 'devbox_modules+=("features/${devbox_remote_provider}.sh")' "$NORM_INSTALL" &&
    grep -Fq 'for devbox_remote_provider in $DEVBOX_REMOTE_PROVIDERS; do' "$INSTALL_SCRIPT" &&
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
# Starts at DEVBOX_REMOTE_PROVIDERS (not DEVBOX_ALL_OPTIONAL_FEATURES) since
# the DEVBOX_REMOTE validation later in this range now reads that registry
# constant.
extract_feature_resolution_block() {
  sed -n '/^readonly DEVBOX_REMOTE_PROVIDERS=/,/^msg_ok "DevBox profile:/p' "$INSTALL_SCRIPT"
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
    grep -Fq 'ubuntu-24.04 | ubuntu-22.04)' "$INSTALL_SCRIPT" &&
    grep -Fq 'add-apt-repository -y universe' "$NORM_FEATURE_BASE"
}

# P2.2: no OTP 29.0.5 artifact exists for 20.04 (see checksums.env), so the
# default profile always failed on it - documented support and the actual
# OS check must not claim otherwise. install.sh must not accept it, and
# the README must say so explicitly rather than silently drop it.
installer_does_not_claim_ubuntu_20_04_support() {
  ! grep -Fq 'ubuntu-20.04' "$INSTALL_SCRIPT" &&
    grep -Fq '20.04' "${PROJECT_ROOT}/README.md" &&
    grep -Fq 'nicht** unterstützt' "${PROJECT_ROOT}/README.md"
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
  local current_version

  current_version="$(grep -oP 'readonly DEVBOX_VERSION="\K[^"]+' "$MANAGER")"

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

  grep -Fq "Update available: ${current_version} -> v99.0.0" "$output_file" &&
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

# Kisuke's remote-info branch, exercised via the same sourced-functions
# pattern as remote_provider_is_persisted_and_migrated_as_happy since
# remote-info reads REMOTE_PROVIDER_FILE, which the compiled manager binary
# cannot be pointed at from the outside. remote_info() dispatches generically
# to "${remote_provider}_remote_info" (see devbox/README.md, "Neuen
# Remote-Provider hinzufügen"), so kisuke_remote_info() has to be sourced
# alongside it.
remote_instructions_are_kisuke_aware() {
  local remote_info_fn kisuke_remote_info_fn output
  remote_info_fn="$(sed -n '/^remote_info() {/,/^}/p' "$MANAGER")"
  kisuke_remote_info_fn="$(sed -n '/^kisuke_remote_info() {/,/^}/p' "$MANAGER")"
  local configured_fn
  configured_fn="$(sed -n '/^configured_remote_provider() {/,/^}/p' "$MANAGER")"

  [[ -n "$remote_info_fn" && -n "$kisuke_remote_info_fn" && -n "$configured_fn" ]] || return 1

  local provider_file="${TEST_TMP}/remote-info-kisuke-provider"
  printf 'kisuke\n' >"$provider_file"

  output="$(bash -c '
    REMOTE_PROVIDER_FILE="'"$provider_file"'"
    '"$configured_fn"'
    '"$kisuke_remote_info_fn"'
    '"$remote_info_fn"'
    remote_info
  ')"

  grep -Fq 'Kisuke Connect remote development' <<<"$output" &&
    grep -Fq 'kisuke connect --headless' <<<"$output" &&
    grep -Fq 'devbox auth login' <<<"$output" &&
    grep -Fq 'devbox ssh setup' <<<"$output" &&
    grep -Fq 'systemctl --user status kisuke' <<<"$output" &&
    grep -Fq 'loginctl enable-linger dev' <<<"$output"
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
    grep -Fq 'write_root_owned_file "${DEV_HOME}/.pgpass" 0600' "$NORM_FEATURE_POSTGRES" &&
    grep -Fq 'write_root_owned_file "$PG_ENV_FILE" 0600' "$NORM_FEATURE_POSTGRES" &&
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
  ! grep -Eq '(@openai/codex|@anthropic-ai/claude-code|@kisuke/cli|[[:space:]]happy)@latest' \
    "$INSTALL_SCRIPT" "$FEATURE_AGENTS" "$FEATURE_HAPPY" "$FEATURE_KISUKE" &&
    grep -Fq '"@openai/codex@${CODEX_VERSION}"' "$FEATURE_AGENTS" &&
    grep -Fq '"@anthropic-ai/claude-code@${CLAUDE_VERSION}"' "$FEATURE_AGENTS" &&
    grep -Fq '"happy@${HAPPY_VERSION}"' "$FEATURE_HAPPY" &&
    grep -Fq '"@kisuke/cli@${KISUKE_VERSION}"' "$FEATURE_KISUKE"
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
    "KISUKE_VERSION": manifest["KISUKE_VERSION"],
    "MULTICA_VERSION": manifest["MULTICA_VERSION"],
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
    grep -Fq 'Kisuke:' <<<"$output" &&
    grep -Fq 'Multica:' <<<"$output" &&
    grep -Fq 'version:)' "$MANAGER" &&
    grep -Fq 'show_version' "$NORM_MANAGER"
}

# P2.1: devbox version --json exposes the same manifest as a JSON object,
# for agents/tooling that would otherwise have to parse the text output.
devbox_version_json_reports_the_manifest() {
  local text_output json_output expected_devbox_version

  text_output="$("$MANAGER" version)"
  json_output="$("$MANAGER" version --json)"
  expected_devbox_version="$(awk -F': +' '/^DevBox:/ { print $2 }' <<<"$text_output")"

  jq -e '.devbox and .node and .erlang and .elixir and .phoenix and .codex_cli and .claude_code and .happy and .kisuke and .multica' \
    <<<"$json_output" >/dev/null &&
    [[ "$(jq -r '.devbox' <<<"$json_output")" == "$expected_devbox_version" ]] &&
    grep -Fq 'version:--json)' "$MANAGER" &&
    grep -Fq 'show_version_json' "$NORM_MANAGER"
}

multica_external_reverse_proxy_is_restricted_and_uses_token_login() {
  local login_fn configure_line authenticated_line

  login_fn="$(sed -n '/^multica_auth_login() {/,/^}/p' "$MANAGER")"
  configure_line="$(grep -n 'multica_configure_public_urls' <<<"$login_fn" | head -n1 | cut -d: -f1)"
  authenticated_line="$(grep -n 'multica_is_authenticated' <<<"$login_fn" | head -n1 | cut -d: -f1)"

  grep -Fq 'DEVBOX_MULTICA_APP_URL' "$FEATURE_MULTICA" &&
    grep -Fq 'DEVBOX_MULTICA_SERVER_URL' "$FEATURE_MULTICA" &&
    grep -Fq 'DEVBOX_MULTICA_PROXY_CIDR' "$FEATURE_MULTICA" &&
    grep -Fq 'MULTICA_TRUSTED_PROXIES=${proxy_cidr}' "$FEATURE_MULTICA" &&
    grep -Fq 'COOKIE_DOMAIN=${cookie_domain}' "$FEATURE_MULTICA" &&
    grep -Fq 'NEXT_PUBLIC_API_URL=${server_url}' "$FEATURE_MULTICA" &&
    grep -Fq 'NEXT_PUBLIC_WS_URL=${public_ws_url}' "$FEATURE_MULTICA" &&
    grep -Fq 'DEVBOX_MULTICA' "$FEATURE_MULTICA" &&
    grep -Fq 'multica login --token' "$MANAGER" &&
    grep -Fq 'reverse-proxied Multica web UI' "$MANAGER" &&
    grep -Fq 'Externer Reverse Proxy' "${PROJECT_ROOT}/README.md" &&
    [[ "$configure_line" -lt "$authenticated_line" ]]
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
    grep -Fq '"${ROOT_STATE_DIR}/install-state.json"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${ROOT_STATE_DIR}/active-ref"' "$INSTALL_SCRIPT"
}

# P1.1: install.sh seeds active-ref with a best-effort release/branch
# classification of DEVBOX_REF, so the first `devbox update` after a fresh
# install has something real to snapshot as "previous" before overwriting
# it (update_devbox() itself always overwrites this with the exact mode it
# already knows, so this guess only matters until the first update).
install_script_classifies_active_ref_mode() {
  local classify_block
  classify_block="$(sed -n '/^if \[\[ "\$DEVBOX_REF" =~/,/^fi$/p' "$INSTALL_SCRIPT")"

  [[ -n "$classify_block" ]] || return 1

  local release_result branch_result

  release_result="$(
    bash -c '
      DEVBOX_REF="v1.2.3"
      '"$classify_block"'
      echo "$devbox_active_mode"
    '
  )"

  branch_result="$(
    bash -c '
      DEVBOX_REF="master"
      '"$classify_block"'
      echo "$devbox_active_mode"
    '
  )"

  [[ "$release_result" == "release" ]] &&
    [[ "$branch_result" == "branch" ]]
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

# P2.3: devbox doctor --json runs the exact same checks as devbox doctor
# (no duplicated logic) and reports the result as the JSON schema from
# #18's audit issue. Builds a fully stubbed environment (PATH shadow +
# readonly-stripped constants) so the result is deterministic regardless
# of this machine's real Codex/Claude/GitHub/Postgres/Happy state.
doctor_json_reports_a_valid_summary_matching_the_exit_code() {
  local bin_dir="${TEST_TMP}/doctor-json-bin"
  local root_state="${TEST_TMP}/doctor-json-root-state"
  local home_dir="${TEST_TMP}/doctor-json-home"
  local ssh_config="${TEST_TMP}/doctor-json-sshd.conf"
  local happy_unit="${TEST_TMP}/doctor-json-happy.service"
  local manager_functions="${TEST_TMP}/manager-functions-doctor-json.sh"
  local devbox_version
  local tool

  devbox_version="$(grep -oP 'readonly DEVBOX_VERSION="\K[^"]+' "$MANAGER")"

  mkdir -p "$bin_dir" "$root_state" "${home_dir}/.happy"

  printf '%s\n' "$devbox_version" >"${root_state}/version"
  printf 'elixir postgres\n' >"${root_state}/installed-features"

  printf 'test-access-key\n' >"${home_dir}/.happy/access.key"
  chmod 0600 "${home_dir}/.happy/access.key"
  chmod 0700 "${home_dir}/.happy"
  printf '{"machineId":"test-machine"}\n' >"${home_dir}/.happy/settings.json"
  printf '{"pid": %d}\n' "$$" >"${home_dir}/.happy/daemon.state.json"
  : >"$happy_unit"

  for tool in claude codex happy fd gh git python3 rg elixir mix psql erl; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${bin_dir}/${tool}"
    chmod 0755 "${bin_dir}/${tool}"
  done

  # is-active/is-enabled succeed (service healthy); is-failed must fail
  # (service is NOT in a failed state) - a stub that always exits 0 would
  # make is-failed report a false failure.
  printf '#!/usr/bin/env bash\ncase "$1" in\n  is-failed) exit 1 ;;\n  *) exit 0 ;;\nesac\n' >"${bin_dir}/systemctl"
  chmod 0755 "${bin_dir}/systemctl"

  printf '#!/usr/bin/env bash\n[[ "$1" == "--version" ]] && echo "v24.0.0"\nexit 0\n' >"${bin_dir}/node"
  chmod 0755 "${bin_dir}/node"

  printf '#!/usr/bin/env bash\necho "|-- happy@1.2.0"\nexit 0\n' >"${bin_dir}/npm"
  chmod 0755 "${bin_dir}/npm"

  # Drop the trailing "main \"\$@\"" call and the readonly keyword so the
  # sourced copy's Root-State/Happy/SSH path constants can be redirected at
  # temp fixtures below, instead of the real /var/lib/devbox and /home/dev.
  sed 's/^readonly //' "$MANAGER" | head -n -1 >"$manager_functions"

  local healthy_output healthy_status=0
  healthy_output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    HOME="$home_dir" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      ROOT_STATE_DIR="'"$root_state"'"
      ROOT_VERSION_FILE="'"${root_state}/version"'"
      FEATURES_FILE="'"${root_state}/installed-features"'"
      INSTALL_STATE_FILE="'"${root_state}/install-state.json"'"
      HAPPY_HOME="'"${home_dir}/.happy"'"
      HAPPY_ACCESS_KEY="'"${home_dir}/.happy/access.key"'"
      HAPPY_SETTINGS="'"${home_dir}/.happy/settings.json"'"
      HAPPY_DAEMON_STATE="'"${home_dir}/.happy/daemon.state.json"'"
      SSH_CONFIG="'"$ssh_config"'"
      HAPPY_SERVICE_UNIT="'"$happy_unit"'"
      doctor json
    '
  )" || healthy_status=$?

  # Now flip the root-state version so it no longer matches the running
  # manager, to exercise the unhealthy path deterministically (a missing
  # PATH stub would silently fall back to a real binary on a real DevBox).
  printf '9.9.9\n' >"${root_state}/version"

  local unhealthy_output unhealthy_status=0
  unhealthy_output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    HOME="$home_dir" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      ROOT_STATE_DIR="'"$root_state"'"
      ROOT_VERSION_FILE="'"${root_state}/version"'"
      FEATURES_FILE="'"${root_state}/installed-features"'"
      INSTALL_STATE_FILE="'"${root_state}/install-state.json"'"
      HAPPY_HOME="'"${home_dir}/.happy"'"
      HAPPY_ACCESS_KEY="'"${home_dir}/.happy/access.key"'"
      HAPPY_SETTINGS="'"${home_dir}/.happy/settings.json"'"
      HAPPY_DAEMON_STATE="'"${home_dir}/.happy/daemon.state.json"'"
      SSH_CONFIG="'"$ssh_config"'"
      HAPPY_SERVICE_UNIT="'"$happy_unit"'"
      doctor json
    '
  )" || unhealthy_status=$?

  jq -e '.healthy == true' <<<"$healthy_output" >/dev/null &&
    [[ "$healthy_status" -eq 0 ]] &&
    [[ "$(jq -r '.devbox_version' <<<"$healthy_output")" == "$devbox_version" ]] &&
    [[ "$(jq -r '.runtime.node' <<<"$healthy_output")" == "24.0.0" ]] &&
    [[ "$(jq -r '.runtime.erlang' <<<"$healthy_output")" != "null" ]] &&
    [[ "$(jq -r '.services.postgres' <<<"$healthy_output")" == "running" ]] &&
    [[ "$(jq -r '.authentication.codex' <<<"$healthy_output")" == "true" ]] &&
    [[ "$(jq -r '.authentication.github' <<<"$healthy_output")" == "true" ]] &&
    [[ "$(jq -r '.security.happy_dir_permissions' <<<"$healthy_output")" == "true" ]] &&
    jq -e '.healthy == false' <<<"$unhealthy_output" >/dev/null &&
    [[ "$unhealthy_status" -eq 1 ]] &&
    grep -Fq 'doctor:--json)' "$MANAGER" &&
    grep -Fq 'doctor json' "$NORM_MANAGER"
}

# P2.2: devbox status is a composite view built from Root-State files and
# the existing per-domain status commands (ssh_status, auth/github/
# openrouter status), not a reimplementation of their checks. Extract the
# function body and re-run it standalone with faked state/collaborators,
# same technique as doctor_checks_root_state_version below.
devbox_status_composes_existing_status_commands() {
  local status_fn
  status_fn="$(sed -n '/^status() {/,/^}/p' "$MANAGER")"

  [[ -n "$status_fn" ]] || return 1

  local root_version_file="${TEST_TMP}/status-root-version"
  local install_state_file="${TEST_TMP}/status-install-state.json"
  local features_file="${TEST_TMP}/status-installed-features"
  local output

  printf '1.2.3\n' >"$root_version_file"
  printf '{"profile":"default"}\n' >"$install_state_file"
  printf 'elixir\n' >"$features_file"

  output="$(
    bash -c '
      ROOT_VERSION_FILE="'"$root_version_file"'"
      INSTALL_STATE_FILE="'"$install_state_file"'"
      FEATURES_FILE="'"$features_file"'"
      feature_was_installed() { grep -Fqw "$1" "$FEATURES_FILE"; }
      ssh_status() { echo "STUB:ssh_status"; }
      run_as_dev() { echo "STUB:run_as_dev:$*"; }
      '"$status_fn"'
      status
    '
  )"

  grep -Fq 'DevBox version:      1.2.3' <<<"$output" &&
    grep -Fq 'Profile:             default' <<<"$output" &&
    grep -Fq 'elixir             enabled' <<<"$output" &&
    grep -Fq 'postgres           disabled' <<<"$output" &&
    grep -Fq 'STUB:ssh_status' <<<"$output" &&
    grep -Eq '^STUB:run_as_dev:.* auth status$' <<<"$output" &&
    grep -Eq '^STUB:run_as_dev:.* github status$' <<<"$output" &&
    grep -Eq '^STUB:run_as_dev:.* openrouter status$' <<<"$output" &&
    grep -Fq 'status:)' "$MANAGER" &&
    grep -Fq 'status' "$NORM_MANAGER"
}

# P1.5: a persisted PGPASSWORD read back from the dev-writable PG_ENV_FILE
# is interpolated directly into ALTER/CREATE ROLE SQL. Extract the
# reuse-or-generate block and confirm a tampered value (SQL/shell
# metacharacters included) is discarded for a fresh password, while a
# value in the actually-generated format (openssl rand -hex 24) passes
# through unchanged - re-installing must not silently rotate a good
# password.
postgres_password_reuse_validates_the_persisted_format() {
  local reuse_block
  reuse_block="$(sed -n '/^  if \[\[ -r "\$PG_ENV_FILE" \]\] &&$/,/^  fi$/p' "$FEATURE_POSTGRES")"

  [[ -n "$reuse_block" ]] || return 1

  local pg_env_file="${TEST_TMP}/postgres-password-env"
  local valid_password="0123456789abcdef0123456789abcdef0123456789abcdef"
  local tampered_output valid_output

  printf "PGPASSWORD=' OR '1'='1\n" >"$pg_env_file"
  tampered_output="$(
    bash -c '
      msg_error() { echo "ERROR: $*" >&2; }
      PG_ENV_FILE="'"$pg_env_file"'"
      '"$reuse_block"'
      echo "PG_DB_PASS=$PG_DB_PASS"
    ' 2>&1
  )"

  printf 'PGPASSWORD=%s\n' "$valid_password" >"$pg_env_file"
  valid_output="$(
    bash -c '
      msg_error() { echo "ERROR: $*" >&2; }
      PG_ENV_FILE="'"$pg_env_file"'"
      '"$reuse_block"'
      echo "PG_DB_PASS=$PG_DB_PASS"
    '
  )"

  local tampered_password
  tampered_password="$(grep -oP '^PG_DB_PASS=\K.*' <<<"$tampered_output")"

  [[ "$tampered_password" != "' OR '1'='1" ]] &&
    [[ "$tampered_password" =~ ^[0-9a-f]{48}$ ]] &&
    grep -Fq 'ERROR: Persisted PostgreSQL password has an unexpected format' <<<"$tampered_output" &&
    [[ "$valid_output" == "PG_DB_PASS=${valid_password}" ]]
}

# Reuse validation must run before the value ever reaches the SQL commands.
postgres_password_is_validated_before_sql_interpolation() {
  local validate_line sql_line

  validate_line="$(grep -n '\^\[0-9a-f\]{48}\$' "$FEATURE_POSTGRES" | head -n1 | cut -d: -f1)"
  sql_line="$(grep -n 'ALTER ROLE' "$FEATURE_POSTGRES" | head -n1 | cut -d: -f1)"

  [[ -n "$validate_line" && -n "$sql_line" ]] &&
    ((validate_line < sql_line))
}

# P1.4: downloaded artifacts without a checksum to verify (OTP/Elixir are
# checksum-verified separately; the mise installer script isn't) used
# predictable, fixed /tmp paths - unpredictable via mktemp closes that gap
# for the artifacts this PR can reasonably harden without taking on an
# external, frequently-changing checksum to maintain for mise.run itself.
temp_artifact_downloads_use_unpredictable_paths() {
  grep -Fq 'otp_tarball="$(mktemp)"' "$FEATURE_ELIXIR" &&
    grep -Fq 'elixir_zip="$(mktemp)"' "$FEATURE_ELIXIR" &&
    grep -Fq 'mise_installer="$(mktemp)"' "$FEATURE_TOOLING" &&
    ! grep -Fq '/tmp/devbox-otp.tar.gz' "$FEATURE_ELIXIR" &&
    ! grep -Fq '/tmp/devbox-elixir.zip' "$FEATURE_ELIXIR" &&
    ! grep -Fq '/tmp/devbox-mise-install.sh' "$FEATURE_TOOLING"
}

# P1.3: install.sh resolves DEVBOX_REF to a commit SHA once, up front, so
# every module fetch in this run (lib/*.sh, features/*.sh, bin/devbox.sh -
# ~10 separate downloads) uses the exact same commit even if the branch
# moves mid-install. Extract the resolution block and exercise both the
# success and the fallback path with a stubbed curl (no real GitHub API
# dependency in this test).
install_pins_module_fetches_to_a_resolved_commit() {
  local resolve_block
  resolve_block="$(sed -n '/^resolve_devbox_ref_to_commit() {/,/^fi$/p' "$INSTALL_SCRIPT")"

  [[ -n "$resolve_block" ]] || return 1

  local bin_dir="${TEST_TMP}/commit-pin-bin"
  mkdir -p "$bin_dir"

  cat <<'EOF' >"${bin_dir}/curl"
#!/usr/bin/env bash
printf '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","other":"noise"}'
EOF
  chmod 0755 "${bin_dir}/curl"

  local output
  output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    bash -c '
      msg_ok() { echo "OK: $*"; }
      msg_info() { echo "INFO: $*"; }
      DEVBOX_GITHUB_REPO="c4kingpin/Scripts"
      DEVBOX_REF="master"
      '"$resolve_block"'
      echo "DEVBOX_REF=$DEVBOX_REF"
      echo "devbox_resolved_commit=$devbox_resolved_commit"
    '
  )"

  grep -Fq "OK: Pinned installer modules to commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" <<<"$output" &&
    grep -Fq "DEVBOX_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" <<<"$output" &&
    grep -Fq "devbox_resolved_commit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" <<<"$output"
}

# A failed/empty API response (rate limit, network blip, nonexistent ref)
# must not block the install - fall back to fetching modules by the ref
# string directly, exactly like every install did before this feature.
install_falls_back_to_the_ref_when_resolution_fails() {
  local resolve_block
  resolve_block="$(sed -n '/^resolve_devbox_ref_to_commit() {/,/^fi$/p' "$INSTALL_SCRIPT")"

  [[ -n "$resolve_block" ]] || return 1

  local bin_dir="${TEST_TMP}/commit-pin-fallback-bin"
  mkdir -p "$bin_dir"

  cat <<'EOF' >"${bin_dir}/curl"
#!/usr/bin/env bash
exit 22
EOF
  chmod 0755 "${bin_dir}/curl"

  local output
  output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    bash -c '
      msg_ok() { echo "OK: $*"; }
      msg_info() { echo "INFO: $*"; }
      DEVBOX_GITHUB_REPO="c4kingpin/Scripts"
      DEVBOX_REF="master"
      '"$resolve_block"'
      echo "DEVBOX_REF=$DEVBOX_REF"
      echo "devbox_resolved_commit=[$devbox_resolved_commit]"
    '
  )"

  grep -Fq "INFO: Could not resolve 'master' to a commit" <<<"$output" &&
    grep -Fq "DEVBOX_REF=master" <<<"$output" &&
    grep -Fq "devbox_resolved_commit=[]" <<<"$output"
}

# P1.2: the LXC E2E test's idempotency re-run now uses the documented
# `curl | bash` one-liner (where $0 is "bash", not a file path) instead of
# downloading to a file first, so that invocation form is actually
# exercised somewhere in CI rather than only asserted against as a README
# string (installer_curl_pipeable_from_master, above).
lxc_integration_test_exercises_the_curl_pipe_path() {
  grep -Fq '| bash"' "$LXC_INTEGRATION_TEST" &&
    grep -Fq '"$invocation" == "pipe"' "$LXC_INTEGRATION_TEST" &&
    grep -Fq 'install_devbox pipe' "$LXC_INTEGRATION_TEST" &&
    grep -Fq -- '-o /tmp/devbox-install.sh && bash /tmp/devbox-install.sh' "$LXC_INTEGRATION_TEST"
}

# P1.1: a real install-A -> update A->B -> rollback -> back-to-A sequence
# against a fully faked Root-State directory (readonly stripped so
# ROOT_STATE_DIR/ACTIVE_REF_FILE/PREVIOUS_REF_FILE can point at a temp
# fixture instead of the real /var/lib/devbox, same technique as the
# doctor --json and workspace tests use).
update_and_rollback_round_trip_restores_the_active_ref() {
  local root_state="${TEST_TMP}/rollback-roundtrip-root-state"
  local bin_dir="${TEST_TMP}/rollback-roundtrip-bin"
  local manager_functions="${TEST_TMP}/rollback-roundtrip-manager-functions.sh"
  local output_file="${TEST_TMP}/rollback-roundtrip-output.log"

  mkdir -p "$root_state" "$bin_dir"

  printf 'release:v1.0.0\n' >"${root_state}/active-ref"

  cat <<'EOF' >"${bin_dir}/curl"
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$arg"
  fi
  prev="$arg"
done
printf '#!/usr/bin/env bash\necho ran fake installer\n' >"$out"
chmod 0755 "$out"
EOF
  chmod 0755 "${bin_dir}/curl"

  sed 's/^readonly //' "$MANAGER" | head -n -1 >"$manager_functions"

  (
    set -Eeuo pipefail
    PATH="${bin_dir}:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$manager_functions"
    # shellcheck disable=SC2034 # read by update_devbox below (sourced at runtime)
    ROOT_STATE_DIR="$root_state"
    ACTIVE_REF_FILE="${root_state}/active-ref"
    PREVIOUS_REF_FILE="${root_state}/previous-ref"
    # shellcheck disable=SC2034 # read by record_previous_update_state below (sourced at runtime)
    PREVIOUS_VERSION_FILE="${root_state}/previous-version"
    # shellcheck disable=SC2317,SC2329
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329
    doctor() { :; }
    # shellcheck disable=SC2317,SC2329
    migrate_legacy_previous_update_state() { :; }

    echo "=== update A(v1.0.0) -> B(v2.0.0) ==="
    update_devbox --to v2.0.0
    echo "active-ref after update: $(<"$ACTIVE_REF_FILE")"
    echo "previous-ref after update: $(<"$PREVIOUS_REF_FILE")"

    echo "=== rollback ==="
    rollback_devbox
    echo "active-ref after rollback: $(<"$ACTIVE_REF_FILE")"
    echo "previous-ref after rollback: $(<"$PREVIOUS_REF_FILE")"
  ) >"$output_file" 2>&1

  grep -Fq "active-ref after update: release:v2.0.0" "$output_file" &&
    grep -Fq "previous-ref after update: release:v1.0.0" "$output_file" &&
    grep -Fq "active-ref after rollback: release:v1.0.0" "$output_file" &&
    grep -Fq "previous-ref after rollback: release:v2.0.0" "$output_file"
}

# P0.2: migrate_legacy_previous_update_state() reads a dev-writable file
# as root (via update_devbox()/rollback_devbox()). It must never `source`
# or `eval` that file's contents - extract the function and run it against
# a file containing a shell-injection payload disguised as a third env
# line, confirming nothing executes, while legitimate KEY=VALUE lines
# still migrate correctly (regression coverage for the existing behavior).
migrate_legacy_previous_update_state_never_executes_file_contents() {
  local migrate_fn
  migrate_fn="$(sed -n '/^migrate_legacy_previous_update_state() {/,/^}/p' "$MANAGER")"

  [[ -n "$migrate_fn" ]] || return 1

  local legacy_file="${TEST_TMP}/legacy-previous-update.env"
  local previous_ref_file="${TEST_TMP}/legacy-previous-ref"
  local previous_version_file="${TEST_TMP}/legacy-previous-version"
  local canary="${TEST_TMP}/legacy-payload-canary"
  local output

  rm -f "$canary" "$previous_ref_file" "$previous_version_file"

  cat <<'EOF' >"$legacy_file"
PREVIOUS_MODE=release
PREVIOUS_TARGET=v1.2.3
PREVIOUS_VERSION=1.2.3
touch TEST_TMP_PLACEHOLDER/legacy-payload-canary
PREVIOUS_TARGET=$(touch TEST_TMP_PLACEHOLDER/legacy-payload-canary)
EOF

  sed -i "s#TEST_TMP_PLACEHOLDER#${TEST_TMP}#g" "$legacy_file"

  output="$(
    bash -c '
      LEGACY_PREVIOUS_UPDATE_FILE="'"$legacy_file"'"
      PREVIOUS_REF_FILE="'"$previous_ref_file"'"
      PREVIOUS_VERSION_FILE="'"$previous_version_file"'"
      '"$migrate_fn"'
      migrate_legacy_previous_update_state
    ' 2>&1
  )"

  [[ ! -e "$canary" ]] &&
    [[ "$(<"$previous_ref_file")" == "release:v1.2.3" ]] &&
    [[ "$(<"$previous_version_file")" == "1.2.3" ]] &&
    [[ ! -f "$legacy_file" ]] &&
    ! grep -Fq 'source' <<<"$(sed -n '/^migrate_legacy_previous_update_state() {/,/^}/p' "$MANAGER")" &&
    [[ -z "$output" ]]
}

# P0.1: a root-executed write into a dev-controlled path must not follow a
# symlink dev planted there in advance. write_root_owned_file() is shared
# by ssh_setup()/ssh_disable() (bin/devbox.sh) and the install.sh feature
# scripts (lib/common.sh's copy); exercise the manager's copy directly by
# extracting it, since both implementations are identical in behavior.
write_root_owned_file_refuses_to_follow_a_symlink() {
  local write_fn reject_fn
  write_fn="$(sed -n '/^write_root_owned_file() {/,/^}/p' "$MANAGER")"
  reject_fn="$(sed -n '/^reject_symlink() {/,/^}/p' "$MANAGER")"

  [[ -n "$write_fn" && -n "$reject_fn" ]] || return 1

  local outside_secret="${TEST_TMP}/write-root-owned-outside-secret"
  local planted_target="${TEST_TMP}/write-root-owned-planted-target"
  local normal_target="${TEST_TMP}/write-root-owned-normal-target"
  local symlink_output normal_output symlink_status=0

  printf 'ORIGINAL' >"$outside_secret"
  ln -s "$outside_secret" "$planted_target"

  symlink_output="$(
    bash -c '
      die() { printf "error - %s\n" "$*" >&2; exit 1; }
      DEV_USER="'"$(id -un)"'"
      '"$reject_fn"'
      '"$write_fn"'
      write_root_owned_file "'"$planted_target"'" 0600 "PWNED"
    ' 2>&1
  )" || symlink_status=$?

  normal_output="$(
    bash -c '
      die() { printf "error - %s\n" "$*" >&2; exit 1; }
      DEV_USER="'"$(id -un)"'"
      '"$reject_fn"'
      '"$write_fn"'
      write_root_owned_file "'"$normal_target"'" 0600 "hello"
    ' 2>&1
  )"

  [[ "$symlink_status" -ne 0 ]] &&
    grep -Fq 'it is a symlink' <<<"$symlink_output" &&
    [[ "$(<"$outside_secret")" == "ORIGINAL" ]] &&
    [[ -z "$normal_output" ]] &&
    [[ "$(<"$normal_target")" == "hello" ]] &&
    [[ "$(stat -c '%a' "$normal_target")" == "600" ]]
}

# lib/user.sh's developer-directory scaffolding runs on every install.sh
# invocation (including devbox update on an already-provisioned box), so a
# symlink dev planted at any of these paths must be rejected before the
# install -d calls that would otherwise chown/chmod through it.
developer_scaffold_dirs_are_symlink_guarded() {
  local dirs_block
  dirs_block="$(sed -n '/for developer_scaffold_dir in /,/^done$/p' "$NORM_LIB_USER")"

  [[ -n "$dirs_block" ]] &&
    grep -Fq 'reject_symlink "$developer_scaffold_dir"' <<<"$dirs_block" &&
    grep -Fq '"${DEV_HOME}/.ssh"' <<<"$dirs_block" &&
    grep -Fq '"${DEV_HOME}/.config/devbox"' <<<"$dirs_block" &&
    grep -Fq '"${DEV_HOME}/workspace"' <<<"$dirs_block"
}

# Static checks that the symlink-unsafe direct-redirect writes identified
# in #18 (P0.1) were actually replaced, not just supplemented.
ssh_commands_use_symlink_safe_writes() {
  grep -Fq 'reject_symlink "${DEV_HOME}/.ssh"' "$MANAGER" &&
    grep -Fq 'write_root_owned_file "$SSH_KEY_FILE" 0600' "$NORM_MANAGER" &&
    grep -Fq 'reject_symlink "$STATE_DIR"' "$MANAGER" &&
    grep -Fq 'write_root_owned_file "$SSH_DISABLED_MARKER" 0600' "$NORM_MANAGER" &&
    ! grep -Fq '>"$SSH_KEY_FILE"' "$NORM_MANAGER" &&
    ! grep -Fq ': >"$SSH_DISABLED_MARKER"' "$NORM_MANAGER"
}

postgres_and_elixir_writes_use_symlink_safe_helper() {
  grep -Fq 'write_root_owned_file "${DEV_HOME}/.erlang.cookie" 0400' "$NORM_FEATURE_ELIXIR" &&
    grep -Fq 'reject_symlink "${DEV_HOME}/.erlang.cookie"' "$FEATURE_ELIXIR" &&
    ! grep -Fq '>"${DEV_HOME}/.erlang.cookie"' "$NORM_FEATURE_ELIXIR" &&
    ! grep -Fq 'cat <<EOF >"${DEV_HOME}/.pgpass"' "$FEATURE_POSTGRES" &&
    ! grep -Fq 'cat <<EOF >"$PG_ENV_FILE"' "$FEATURE_POSTGRES"
}

# P2.1: DEVBOX_VERSION alone doesn't uniquely identify installed code, so
# devbox version/status also report the installed commit (persisted by
# install.sh, P1.3).
devbox_version_reports_the_installed_commit() {
  local text_output json_output

  text_output="$("$MANAGER" version)"
  json_output="$("$MANAGER" version --json)"

  grep -Fq 'Commit:' <<<"$text_output" &&
    jq -e '.commit' <<<"$json_output" >/dev/null &&
    grep -Fq 'installed_commit' "$MANAGER"
}

# update --check on a branch used to only say "not version-compared"; it
# now resolves the branch's current remote commit and compares it against
# the locally installed one, so a real "up to date"/"update available"
# state exists for branch updates too, not just releases.
update_check_compares_branch_commits() {
  local root_state="${TEST_TMP}/update-check-commit-root-state"
  local bin_dir="${TEST_TMP}/update-check-commit-bin"
  local manager_functions="${TEST_TMP}/update-check-commit-manager-functions.sh"
  local up_to_date_output stale_output

  mkdir -p "$root_state" "$bin_dir"

  cat <<'EOF' >"${bin_dir}/curl"
#!/usr/bin/env bash
url="${!#}"
case "$url" in
*/commits/feature-branch)
  echo '{"sha":"cccccccccccccccccccccccccccccccccccccccc"}'
  ;;
*)
  echo "unexpected curl invocation: $url" >&2
  exit 22
  ;;
esac
EOF
  chmod 0755 "${bin_dir}/curl"

  sed 's/^readonly //' "$MANAGER" | head -n -1 >"$manager_functions"

  printf 'cccccccccccccccccccccccccccccccccccccccc\n' >"${root_state}/commit"
  up_to_date_output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      ROOT_COMMIT_FILE="'"${root_state}/commit"'"
      require_root() { :; }
      update_devbox --branch feature-branch --check
    '
  )"

  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"${root_state}/commit"
  stale_output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      ROOT_COMMIT_FILE="'"${root_state}/commit"'"
      require_root() { :; }
      update_devbox --branch feature-branch --check
    '
  )"

  grep -Fq "Already up to date (branch 'feature-branch' at cccccccccccccccccccccccccccccccccccccccc)" <<<"$up_to_date_output" &&
    grep -Fq "Update available on branch 'feature-branch': aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -> cccccccccccccccccccccccccccccccccccccccc" <<<"$stale_output"
}

# P2.3: `VAR=value curl ... | bash` only sets VAR in curl's process, not
# bash's - README examples must put the override on the bash side of the
# pipe (`curl ... | env VAR=value bash`) for it to actually reach the
# installer.
readme_pipe_examples_pass_env_vars_to_bash_not_curl() {
  ! grep -Eq '^(DEVBOX_PROFILE|DEVBOX_FEATURES|DEVBOX_AUTONOMY|SSH_AUTHORIZED_KEY)=.*\\$' \
    "${PROJECT_ROOT}/README.md" &&
    grep -Fq 'env DEVBOX_PROFILE=minimal bash' "${PROJECT_ROOT}/README.md" &&
    grep -Fq 'env DEVBOX_FEATURES=postgres bash' "${PROJECT_ROOT}/README.md" &&
    grep -Fq 'env DEVBOX_AUTONOMY=autonomous bash' "${PROJECT_ROOT}/README.md" &&
    grep -Fq 'env SSH_AUTHORIZED_KEY=' "${PROJECT_ROOT}/README.md"
}

# P2.4: SC2086/SC2154 catch real word-splitting/quoting and
# unassigned-variable bugs; a global --exclude for them can let a real new
# finding pass silently. A repo-wide `shellcheck -x --exclude=SC1090,SC1091`
# pass (i.e. everything except the two that are structurally unavoidable -
# dynamically sourced, downloaded modules shellcheck can't statically
# follow) currently finds nothing to disable locally, so no per-line
# `# shellcheck disable=SC2086` exceptions exist anywhere in the repo
# either. This only guards against the global exclusion creeping back into
# CI/docs; it isn't itself a substitute for the "Run ShellCheck" CI step.
shellcheck_exceptions_are_not_globally_disabled() {
  local repo_root="${PROJECT_ROOT}/.."

  ! grep -Fq 'SC2086' "${repo_root}/.github/workflows/ci.yml" &&
    ! grep -Fq 'SC2154' "${repo_root}/.github/workflows/ci.yml" &&
    ! grep -Fq 'SC2086' "${repo_root}/README.md" &&
    ! grep -Fq 'SC2154' "${repo_root}/README.md" &&
    ! grep -Fq 'SC2086' "${PROJECT_ROOT}/README.md" &&
    ! grep -Fq 'SC2154' "${PROJECT_ROOT}/README.md" &&
    grep -Fq 'exclude=SC1090,SC1091' "${repo_root}/.github/workflows/ci.yml"
}

# P3 (#10/#27): redis is a fully optional feature module, following the
# same shape as postgres/elixir - its own features/*.sh file, gated by
# feature_enabled/feature_was_installed, never on by default in either
# built-in profile (opt in explicitly via DEVBOX_FEATURES).
redis_is_a_separate_optional_feature_disabled_by_default() {
  grep -Fq 'DEVBOX_ALL_OPTIONAL_FEATURES="elixir postgres redis"' "$INSTALL_SCRIPT" &&
    grep -Fq 'default) devbox_profile_features="elixir postgres" ;;' "$INSTALL_SCRIPT" &&
    grep -Fq 'minimal) devbox_profile_features="" ;;' "$INSTALL_SCRIPT" &&
    grep -Fq 'features/redis.sh' "$INSTALL_SCRIPT" &&
    grep -Fq 'if feature_enabled redis; then' "$INSTALL_SCRIPT" &&
    grep -Fq 'install_redis_package' "$INSTALL_SCRIPT" &&
    grep -Fq 'enable_redis_service' "$INSTALL_SCRIPT" &&
    grep -Fq 'install_redis_package() {' "$FEATURE_REDIS" &&
    grep -Fq 'enable_redis_service() {' "$FEATURE_REDIS" &&
    grep -Fq 'redis-server' "$FEATURE_REDIS"
}

redis_validation_and_doctor_are_feature_aware() {
  local validation_block
  validation_block="$(sed -n '/^msg_info "Validating Installation"/,/^msg_ok "Validated Installation"/p' "$INSTALL_SCRIPT")"

  grep -Fq 'if feature_enabled redis; then' <<<"$validation_block" &&
    grep -Fq 'redis-server.service' <<<"$validation_block" &&
    grep -Fq 'feature_was_installed redis' "$MANAGER" &&
    grep -Fq 'redis-cli' "$MANAGER" &&
    grep -Fq 'redis: (if $redis == "" then null else $redis end)' "$NORM_MANAGER"
}

# #43: the remote-access layer is a swappable, optional provider - Happy
# stays the default, Kisuke is an alternative, and DEVBOX_REMOTE=none must
# produce a fully usable DevBox that never installs or configures either.
# DEVBOX_REMOTE is validated against the single-source-of-truth
# DEVBOX_REMOTE_PROVIDERS registry (plus the always-valid "none"), the same
# pattern install.sh already used for DEVBOX_ALL_OPTIONAL_FEATURES.
devbox_remote_defaults_to_happy_and_validates_input() {
  grep -Fq 'DEVBOX_REMOTE="${DEVBOX_REMOTE:-happy}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'readonly DEVBOX_REMOTE_PROVIDERS="happy kisuke multica"' "$INSTALL_SCRIPT" &&
    grep -Fq '" $DEVBOX_REMOTE_PROVIDERS " != *" $DEVBOX_REMOTE "*' "$NORM_INSTALL" &&
    grep -Fq 'Invalid DEVBOX_REMOTE' "$INSTALL_SCRIPT"
}

interactive_multica_setup_can_collect_reverse_proxy_configuration() {
  grep -Fq 'DEVBOX_REMOTE_INTERACTIVE_SELECTION=0' "$INSTALL_SCRIPT" &&
    grep -Fq 'select_multica_reverse_proxy() {' "$INSTALL_SCRIPT" &&
    grep -Fq 'Use an external reverse proxy on another host?' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_MULTICA_APP_URL' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_MULTICA_SERVER_URL' "$INSTALL_SCRIPT" &&
    grep -Fq 'DEVBOX_MULTICA_PROXY_CIDR' "$INSTALL_SCRIPT" &&
    grep -Fq 'select_multica_reverse_proxy' "$INSTALL_SCRIPT"
}

# Each remote provider is a module (features/<name>.sh) exposing four hooks
# install.sh dispatches to generically - remote_install_<name>,
# remote_bashrc_<name>, remote_validate_<name>, remote_banner_<name> (see
# devbox/README.md, "Neuen Remote-Provider hinzufügen"). These tests check
# both ends: install.sh's generic dispatch, and that each provider's own
# module actually defines and wires the hook.
install_gates_happy_installation_on_remote_provider() {
  grep -Fq 'if [[ "$DEVBOX_REMOTE" != "none" ]]; then' "$NORM_INSTALL" &&
    grep -Fq '"remote_install_${DEVBOX_REMOTE}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'remote_install_happy() {' "$FEATURE_HAPPY" &&
    grep -Fq 'install_happy' "$NORM_FEATURE_HAPPY" &&
    grep -Fq 'install_happy_daemon_service' "$NORM_FEATURE_HAPPY" &&
    grep -Fq 'printf '\''%s\n'\'' "$DEVBOX_REMOTE" >"${ROOT_STATE_DIR}/remote-provider"' "$INSTALL_SCRIPT" &&
    grep -Fq '"remote": "${DEVBOX_REMOTE}"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${ROOT_STATE_DIR}/remote-provider"' "$NORM_INSTALL"
}

install_gates_kisuke_installation_on_remote_provider() {
  grep -Fq 'if [[ "$DEVBOX_REMOTE" != "none" ]]; then' "$NORM_INSTALL" &&
    grep -Fq '"remote_install_${DEVBOX_REMOTE}"' "$INSTALL_SCRIPT" &&
    grep -Fq 'remote_install_kisuke() {' "$FEATURE_KISUKE" &&
    grep -Fq 'install_kisuke' "$NORM_FEATURE_KISUKE" &&
    grep -Fq 'enable_kisuke_user_linger' "$NORM_FEATURE_KISUKE"
}

# No REMOTE_PROVIDER_FILE means the box predates #43, when Happy was
# unconditionally installed - migrating it as "happy" (not "unknown" or
# erroring) is the whole backward-compatibility point.
remote_provider_is_persisted_and_migrated_as_happy() {
  local configured_fn
  configured_fn="$(sed -n '/^configured_remote_provider() {/,/^}/p' "$MANAGER")"

  [[ -n "$configured_fn" ]] || return 1

  local provider_file="${TEST_TMP}/remote-provider-migration-test"
  local happy_result kisuke_result none_result missing_result

  printf 'happy\n' >"$provider_file"
  happy_result="$(bash -c 'REMOTE_PROVIDER_FILE="'"$provider_file"'"; '"$configured_fn"'; configured_remote_provider')"

  printf 'kisuke\n' >"$provider_file"
  kisuke_result="$(bash -c 'REMOTE_PROVIDER_FILE="'"$provider_file"'"; '"$configured_fn"'; configured_remote_provider')"

  printf 'none\n' >"$provider_file"
  none_result="$(bash -c 'REMOTE_PROVIDER_FILE="'"$provider_file"'"; '"$configured_fn"'; configured_remote_provider')"

  missing_result="$(bash -c 'REMOTE_PROVIDER_FILE="'"${TEST_TMP}/does-not-exist"'"; '"$configured_fn"'; configured_remote_provider')"

  [[ "$happy_result" == "happy" ]] &&
    [[ "$kisuke_result" == "kisuke" ]] &&
    [[ "$none_result" == "none" ]] &&
    [[ "$missing_result" == "happy" ]]
}

# devbox status/doctor must reflect and respect the configured provider:
# status shows it, doctor --json reports it, and doctor's Happy/Kisuke-
# specific checks (pairing, daemon, boot service, credential permissions)
# are skipped entirely - not just reported as failing - when it's "none".
status_and_doctor_are_remote_provider_aware() {
  grep -Fq 'configured_remote_provider' "$MANAGER" &&
    grep -Fq 'Remote provider:' "$NORM_MANAGER" &&
    grep -Fq 'remote_provider: $remote_provider' "$NORM_MANAGER" &&
    grep -Fq 'if [[ "$remote_provider" == "happy" ]]; then' "$NORM_MANAGER" &&
    grep -Fq 'elif [[ "$remote_provider" == "kisuke" ]]; then' "$NORM_MANAGER" &&
    grep -Fq 'Happy is paired' "$MANAGER" &&
    grep -Fq 'Kisuke is authenticated' "$MANAGER"
}

# update_devbox() must thread the box's existing provider selection back
# into the re-run installer, not let it silently fall back to "happy".
update_devbox_passes_through_the_persisted_remote_provider() {
  local fake_repo="${TEST_TMP}/remote-provider-update-fake-repo"
  local output_file="${TEST_TMP}/remote-provider-update-output.log"
  local bin_dir="${TEST_TMP}/remote-provider-update-bin"
  local manager_functions="${TEST_TMP}/remote-provider-update-manager-functions.sh"
  local provider_file="${TEST_TMP}/remote-provider-update-state"

  mkdir -p "$fake_repo" "$bin_dir"
  printf 'none\n' >"$provider_file"

  cat <<'EOF' >"${fake_repo}/install.sh"
#!/usr/bin/env bash
echo "DEVBOX_REMOTE=${DEVBOX_REMOTE:-<unset>}"
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
cp "${fake_repo}/install.sh" "\$out"
EOF
  chmod 0755 "${bin_dir}/curl"

  sed 's/^readonly //' "$MANAGER" | head -n -1 >"$manager_functions"

  (
    set -Eeuo pipefail
    PATH="${bin_dir}:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$manager_functions"
    # shellcheck disable=SC2034 # read by update_devbox below (sourced at runtime)
    REMOTE_PROVIDER_FILE="$provider_file"
    # shellcheck disable=SC2317,SC2329
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329
    doctor() { :; }
    update_devbox --branch feature-branch
  ) >"$output_file" 2>&1 || true

  grep -Fq "DEVBOX_REMOTE=none" "$output_file"
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
    grep -Fq 'remote_install_happy() {' "$FEATURE_HAPPY" &&
    grep -Fq 'install_happy_daemon_service' "$NORM_FEATURE_HAPPY" &&
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
    grep -Fq 'remote_validate_happy() {' "$FEATURE_HAPPY" &&
    grep -Fq 'systemctl is-enabled --quiet devbox-happy-daemon.service' "$NORM_FEATURE_HAPPY"
}

# The .bashrc logic stays as a fallback for boxes whose service is missing
# or disabled (issue #19 explicitly asks for it to be kept). It now lives in
# features/happy.sh's remote_bashrc_happy() hook, dispatched generically by
# install.sh - see devbox/README.md, "Neuen Remote-Provider hinzufügen".
happy_bashrc_start_remains_as_fallback() {
  grep -Fq 'remote_bashrc_happy() {' "$FEATURE_HAPPY" &&
    grep -Fq '# DevBox Happy' "$FEATURE_HAPPY" &&
    grep -Fq 'HAPPY_DAEMON_CHECKED' "$FEATURE_HAPPY" &&
    grep -Fq 'happy daemon start' "$FEATURE_HAPPY" &&
    grep -Fq '"remote_bashrc_${DEVBOX_REMOTE}"' "$INSTALL_SCRIPT"
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

# Kisuke Connect (#43 alternative remote provider): `kisuke run` blocks in
# the foreground (unlike `happy daemon start`, which forks and returns), so
# devbox's own unit is a plain Type=simple + Restart=on-failure supervisor
# rather than Happy's oneshot+PID-file wrapper - see features/kisuke.sh's
# header comment for why kisuke's own `--service-level system` isn't used
# instead.
# Unlike Happy (which forks a background daemon directly, no systemd
# involved), Kisuke's own guided setup (`kisuke connect`) manages its own
# systemd --user unit and needs `systemctl --user` reachable the first time
# it runs - impossible in a fresh LXC container, which has no D-Bus user
# session until someone logs in interactively. `loginctl enable-linger`
# is the standard fix: a persistent user session (and its bus) starts at
# boot regardless of login. See features/kisuke.sh's header comment for the
# full chicken-and-egg problem this avoids.
kisuke_gets_a_lingering_user_session_for_its_own_service_management() {
  grep -Fq 'enable_kisuke_user_linger() {' "$FEATURE_KISUKE" &&
    grep -Fq 'loginctl enable-linger "$DEV_USER"' "$FEATURE_KISUKE" &&
    grep -Fq 'remote_install_kisuke() {' "$FEATURE_KISUKE" &&
    grep -Fq 'enable_kisuke_user_linger' "$NORM_FEATURE_KISUKE" &&
    grep -Fq 'remote_validate_kisuke() {' "$FEATURE_KISUKE" &&
    grep -Fq 'loginctl show-user "$DEV_USER" --property=Linger --value' "$NORM_FEATURE_KISUKE" &&
    # Setting the linger flag alone doesn't guarantee systemd-logind has
    # already finished starting the user manager/bus by the time this
    # function returns (observed in practice - see the header comment
    # above) - start it explicitly and wait for its bus socket instead of
    # just hoping the flag took effect immediately.
    grep -Fq 'systemctl start "user@${dev_uid}.service"' "$NORM_FEATURE_KISUKE" &&
    grep -Fq '[[ ! -S "/run/user/${dev_uid}/bus" ]]' "$NORM_FEATURE_KISUKE" &&
    grep -Fq 'did not come up within 15s' "$FEATURE_KISUKE"
}

# `sudo -iu dev` (the documented way to enter this box, see install.sh's own
# final instructions) simulates a login shell but does not register a
# systemd-logind session, so it never sets XDG_RUNTIME_DIR - reported in
# practice as `systemctl --user` (including Kisuke's own) failing with
# "Failed to connect to bus: No medium found" even though
# enable_kisuke_user_linger()'s lingering session and its bus socket were
# confirmed up and healthy. /etc/profile.d/devbox.sh is rewritten on every
# install/update (unlike marker-guarded ~/.bashrc blocks), so fixing it
# there also reaches boxes that installed before this fix once they update.
devbox_profile_sets_xdg_runtime_dir_for_sudo_iu_shells() {
  local profile_block
  profile_block="$(sed -n "/^cat <<'EOF' >\/etc\/profile.d\/devbox.sh\$/,/^EOF\$/p" "$INSTALL_SCRIPT")"

  [[ -n "$profile_block" ]] || return 1

  grep -Fq 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' <<<"$profile_block" &&
    grep -Fq '[[ -z "${XDG_RUNTIME_DIR:-}" ]]' <<<"$profile_block"
}

# The .bashrc logic stays as a fallback for boxes whose systemd --user unit
# is installed but didn't come up this boot, mirroring Happy's issue #19
# fallback - just against `systemctl --user`, since Kisuke (unlike Happy)
# manages its own unit rather than one DevBox writes.
kisuke_bashrc_start_remains_as_fallback() {
  grep -Fq 'remote_bashrc_kisuke() {' "$FEATURE_KISUKE" &&
    grep -Fq '# DevBox Kisuke' "$FEATURE_KISUKE" &&
    grep -Fq 'KISUKE_DAEMON_CHECKED' "$FEATURE_KISUKE" &&
    grep -Fq 'systemctl --user start kisuke' "$FEATURE_KISUKE" &&
    grep -Fq '"remote_bashrc_${DEVBOX_REMOTE}"' "$INSTALL_SCRIPT"
}

# devbox auth login's Kisuke branch has to run `kisuke connect`, not
# `kisuke login`: `kisuke run`/`kisuke login` alone deadlock in a headless
# container (see features/kisuke.sh) - only the guided `connect` path
# installs+starts Kisuke's own service and completes login in one step.
auth_login_uses_kisuke_connect_not_bare_login() {
  grep -Fq 'kisuke connect' "$NORM_MANAGER" &&
    ! grep -Fq 'kisuke login --headless' "$NORM_MANAGER" &&
    ! grep -Fq 'kisuke run' "$NORM_MANAGER"
}

doctor_checks_kisuke_daemon_service() {
  grep -Fq 'readonly KISUKE_SERVICE="kisuke"' "$MANAGER" &&
    grep -Fq 'kisuke_daemon_service_is_installed() {' "$MANAGER" &&
    grep -Fq 'kisuke_daemon_service_is_enabled() {' "$MANAGER" &&
    grep -Fq 'systemctl --user cat "$1"' "$NORM_MANAGER" &&
    grep -Fq 'systemctl --user is-enabled --quiet "$1"' "$NORM_MANAGER" &&
    grep -Fq 'systemctl --user is-active --quiet "$1"' "$NORM_MANAGER" &&
    grep -Fq 'is not installed yet; run: devbox auth login' "$MANAGER" &&
    # doctor shells out to `kisuke whoami`, not a file-based guess, since
    # Kisuke's on-disk format isn't documented the way Happy's is.
    grep -Fq 'run_as_dev kisuke whoami' "$NORM_MANAGER"
}

# doctor --json's Kisuke fields, exercised against a real fixture (auth
# token + pid file + service unit) the same way
# doctor_json_reports_a_valid_summary_matching_the_exit_code exercises
# Happy's.
# doctor --json's Kisuke fields, exercised the same way
# doctor_json_reports_a_valid_summary_matching_the_exit_code exercises
# Happy's - but Kisuke's checks shell out to `kisuke whoami` and
# `systemctl --user`, not raw state files (its on-disk format isn't
# documented the way Happy's access.key/settings.json are), so the fixture
# is just stubbed commands rather than a fake ~/.kisuke layout.
doctor_json_reports_kisuke_fields() {
  local bin_dir="${TEST_TMP}/doctor-json-kisuke-bin"
  local root_state="${TEST_TMP}/doctor-json-kisuke-root-state"
  local home_dir="${TEST_TMP}/doctor-json-kisuke-home"
  local ssh_config="${TEST_TMP}/doctor-json-kisuke-sshd.conf"
  local provider_file="${TEST_TMP}/doctor-json-kisuke-remote-provider"
  local manager_functions="${TEST_TMP}/manager-functions-doctor-json-kisuke.sh"
  local devbox_version
  local tool

  devbox_version="$(grep -oP 'readonly DEVBOX_VERSION="\K[^"]+' "$MANAGER")"

  mkdir -p "$bin_dir" "$root_state" "${home_dir}/.kisuke"
  chmod 0700 "${home_dir}/.kisuke"

  printf '%s\n' "$devbox_version" >"${root_state}/version"
  printf '\n' >"${root_state}/installed-features"
  printf 'kisuke\n' >"$provider_file"

  for tool in claude codex kisuke fd gh git python3 rg; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${bin_dir}/${tool}"
    chmod 0755 "${bin_dir}/${tool}"
  done

  # `systemctl --user cat/is-enabled/is-active kisuke[.service]` and
  # `kisuke whoami` all succeed - a fully authenticated, running box.
  printf '#!/usr/bin/env bash\ncase "$*" in\n  *is-failed*) exit 1 ;;\n  *) exit 0 ;;\nesac\n' >"${bin_dir}/systemctl"
  chmod 0755 "${bin_dir}/systemctl"

  printf '#!/usr/bin/env bash\n[[ "$1" == "--version" ]] && echo "v24.0.0"\nexit 0\n' >"${bin_dir}/node"
  chmod 0755 "${bin_dir}/node"

  printf '#!/usr/bin/env bash\necho "|-- @kisuke/cli@1.2.20"\nexit 0\n' >"${bin_dir}/npm"
  chmod 0755 "${bin_dir}/npm"

  sed 's/^readonly //' "$MANAGER" | head -n -1 >"$manager_functions"

  local output status=0
  output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    HOME="$home_dir" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      ROOT_STATE_DIR="'"$root_state"'"
      ROOT_VERSION_FILE="'"${root_state}/version"'"
      FEATURES_FILE="'"${root_state}/installed-features"'"
      INSTALL_STATE_FILE="'"${root_state}/install-state.json"'"
      REMOTE_PROVIDER_FILE="'"$provider_file"'"
      KISUKE_HOME="'"${home_dir}/.kisuke"'"
      SSH_CONFIG="'"$ssh_config"'"
      doctor json
    '
  )" || status=$?

  jq -e '.healthy == true' <<<"$output" >/dev/null &&
    [[ "$status" -eq 0 ]] &&
    [[ "$(jq -r '.remote_provider' <<<"$output")" == "kisuke" ]] &&
    [[ "$(jq -r '.services.kisuke_daemon' <<<"$output")" == "running" ]] &&
    [[ "$(jq -r '.authentication.kisuke' <<<"$output")" == "true" ]] &&
    [[ "$(jq -r '.security.kisuke_dir_permissions' <<<"$output")" == "true" ]]
}

# Reported in practice: a box that hasn't completed `devbox auth login` yet
# (or hit one of #69/#70's transient D-Bus races partway through
# `kisuke connect`) can have the "kisuke" systemd --user unit installed but
# not enabled, and not be authenticated - install.sh/devbox update both run
# `devbox doctor` as a hard validation step at the end, so a doctor that
# treated this expected, self-resolving state as fatal (status=1) aborted
# the entire install/update over it. None of this is fatal: `devbox auth
# login` is what's expected to resolve it.
doctor_json_kisuke_not_yet_configured_is_still_healthy() {
  local bin_dir="${TEST_TMP}/doctor-json-kisuke-partial-bin"
  local root_state="${TEST_TMP}/doctor-json-kisuke-partial-root-state"
  local home_dir="${TEST_TMP}/doctor-json-kisuke-partial-home"
  local ssh_config="${TEST_TMP}/doctor-json-kisuke-partial-sshd.conf"
  local provider_file="${TEST_TMP}/doctor-json-kisuke-partial-remote-provider"
  local manager_functions="${TEST_TMP}/manager-functions-doctor-json-kisuke-partial.sh"
  local devbox_version
  local tool

  devbox_version="$(grep -oP 'readonly DEVBOX_VERSION="\K[^"]+' "$MANAGER")"

  mkdir -p "$bin_dir" "$root_state" "${home_dir}/.kisuke"
  chmod 0700 "${home_dir}/.kisuke"

  printf '%s\n' "$devbox_version" >"${root_state}/version"
  printf '\n' >"${root_state}/installed-features"
  printf 'kisuke\n' >"$provider_file"

  for tool in claude codex fd gh git python3 rg; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${bin_dir}/${tool}"
    chmod 0755 "${bin_dir}/${tool}"
  done

  # Not authenticated: `kisuke whoami` fails.
  printf '#!/usr/bin/env bash\nexit 1\n' >"${bin_dir}/kisuke"
  chmod 0755 "${bin_dir}/kisuke"

  # Unit installed (`cat` succeeds) but neither enabled nor active/running -
  # the exact partial state reported in practice.
  printf '#!/usr/bin/env bash\ncase "$*" in\n  *cat*) exit 0 ;;\n  *) exit 1 ;;\nesac\n' >"${bin_dir}/systemctl"
  chmod 0755 "${bin_dir}/systemctl"

  printf '#!/usr/bin/env bash\n[[ "$1" == "--version" ]] && echo "v24.0.0"\nexit 0\n' >"${bin_dir}/node"
  chmod 0755 "${bin_dir}/node"

  printf '#!/usr/bin/env bash\necho "|-- @kisuke/cli@1.2.20"\nexit 0\n' >"${bin_dir}/npm"
  chmod 0755 "${bin_dir}/npm"

  sed 's/^readonly //' "$MANAGER" | head -n -1 >"$manager_functions"

  local output status=0
  output="$(
    PATH="${bin_dir}:/usr/bin:/bin" \
    HOME="$home_dir" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$manager_functions"'"
      ROOT_STATE_DIR="'"$root_state"'"
      ROOT_VERSION_FILE="'"${root_state}/version"'"
      FEATURES_FILE="'"${root_state}/installed-features"'"
      INSTALL_STATE_FILE="'"${root_state}/install-state.json"'"
      REMOTE_PROVIDER_FILE="'"$provider_file"'"
      KISUKE_HOME="'"${home_dir}/.kisuke"'"
      SSH_CONFIG="'"$ssh_config"'"
      doctor json
    '
  )" || status=$?

  jq -e '.healthy == true' <<<"$output" >/dev/null &&
    [[ "$status" -eq 0 ]] &&
    [[ "$(jq -r '.authentication.kisuke' <<<"$output")" == "false" ]] &&
    [[ "$(jq -r '.services.kisuke_daemon' <<<"$output")" == "not running" ]]
}

# Issue #59: a Claude/Codex session that can't proceed because of a
# usage/rate limit must push a Happy notification instead of just going
# silent. install_agent_limit_notify has to run after Happy (it shells out
# to `happy notify`) and wire both agents up: a Claude StopFailure hook
# (matcher: rate_limit|billing_error) and a Codex `notify` command.
# install_agent_limit_notify has to live inside remote_install_happy()
# (features/happy.sh) - the notify scripts shell out to `happy notify`, so
# they're pointless (and shouldn't be installed) on a box configured with a
# different remote provider or none at all. See devbox/README.md, "Neuen
# Remote-Provider hinzufügen".
extract_first_happy_remote_gate() {
  sed -n '/^remote_install_happy() {/,/^}/p' "$FEATURE_HAPPY"
}

agent_limit_notify_is_installed_and_wired() {
  local happy_gate
  happy_gate="$(extract_first_happy_remote_gate)"

  grep -Fq 'install_agent_limit_notify() {' "$FEATURE_AGENT_NOTIFY" &&
    grep -Fq 'install_happy' <<<"$happy_gate" &&
    grep -Fq 'install_happy_daemon_service' <<<"$happy_gate" &&
    grep -Fq 'install_agent_limit_notify' <<<"$happy_gate" &&
    (($(grep -Fn 'install_happy_daemon_service' <<<"$happy_gate" | head -1 | cut -d: -f1) \
      < $(grep -Fn 'install_agent_limit_notify' <<<"$happy_gate" | head -1 | cut -d: -f1))) &&
    # Only Happy's module wires up limit notifications - Kisuke (and any
    # future provider) has to opt in explicitly, it's not a DevBox-wide
    # default.
    ! grep -Fq 'install_agent_limit_notify' "$FEATURE_KISUKE" &&
    grep -Fq '"${DEV_HOME}/.local/bin/devbox-agent-limit-notify"' "$FEATURE_AGENT_NOTIFY" &&
    grep -Fq '"${DEV_HOME}/.local/bin/devbox-claude-limit-detect"' "$FEATURE_AGENT_NOTIFY" &&
    grep -Fq '"${DEV_HOME}/.local/bin/devbox-codex-limit-detect"' "$FEATURE_AGENT_NOTIFY" &&
    grep -Fq 'chmod 0755 "${DEV_HOME}/.local/bin/devbox-agent-limit-notify" "${DEV_HOME}/.local/bin/devbox-claude-limit-detect" "${DEV_HOME}/.local/bin/devbox-codex-limit-detect"' "$NORM_FEATURE_AGENT_NOTIFY" &&
    # Claude: registered as a StopFailure hook filtered to limit-shaped errors.
    grep -Fq '"StopFailure"' "$INSTALL_SCRIPT" &&
    grep -Fq '"matcher": "rate_limit|billing_error"' "$INSTALL_SCRIPT" &&
    grep -Fq '"${DEV_HOME}/.local/bin/devbox-claude-limit-detect"' "$INSTALL_SCRIPT" &&
    # Codex: registered via config.toml's notify hook on a fresh install; an
    # existing config.toml is left alone (same as the rest of that block).
    grep -Fq 'notify = ["${DEV_HOME}/.local/bin/devbox-codex-limit-detect"]' "$INSTALL_SCRIPT" &&
    grep -Fq 'Preserving existing ~/.codex/config.toml' "$INSTALL_SCRIPT" &&
    grep -Fq 'devbox-codex-limit-detect' "$NORM_INSTALL"
}

# The jq merge that adds the StopFailure hook to an *existing*
# ~/.claude/settings.json (a fresh install gets it straight from the
# heredoc) has to be idempotent, same as the neighboring
# permissions.deny merge it extends.
extract_claude_settings_merge_filter() {
  local start end

  start="$(grep -Fn "      --arg command \"\${DEV_HOME}/.local/bin/devbox-claude-limit-detect\" \\" "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
  end="$(grep -Fn "    ' \\" "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"

  [[ -n "$start" && -n "$end" && "$end" -gt "$start" ]] || return 1

  # +2 skips the --arg line and the opening quote-only line.
  sed -n "$((start + 2)),$((end - 1))p" "$INSTALL_SCRIPT"
}

claude_settings_hook_merge_is_idempotent() {
  local command_path="/home/dev/.local/bin/devbox-claude-limit-detect"
  local input="${TEST_TMP}/claude-settings-merge-input.json"
  local once="${TEST_TMP}/claude-settings-merge-once.json"
  local twice="${TEST_TMP}/claude-settings-merge-twice.json"
  local filter

  filter="$(extract_claude_settings_merge_filter)"
  [[ -n "$filter" ]] || return 1

  cat <<'EOF' >"$input"
{
  "permissions": {"deny": ["Read(./.env)"]},
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hi"}]}]}
}
EOF

  jq --arg command "$command_path" "$filter" "$input" >"$once" || return 1
  jq --arg command "$command_path" "$filter" "$once" >"$twice" || return 1

  # Existing hooks (PreToolUse) and the deny merge stay untouched.
  [[ "$(jq '.hooks.PreToolUse | length' "$once")" == "1" ]] &&
    [[ "$(jq '.permissions.deny | length' "$once")" == "4" ]] &&
    # Exactly one StopFailure entry, not duplicated on a second run.
    [[ "$(jq '.hooks.StopFailure | length' "$once")" == "1" ]] &&
    [[ "$(jq '.hooks.StopFailure | length' "$twice")" == "1" ]] &&
    [[ "$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$once")" == "$command_path" ]] &&
    [[ "$(jq -r '.hooks.StopFailure[0].matcher' "$once")" == "rate_limit|billing_error" ]]
}

extract_agent_limit_notify_scripts() {
  local dest_dir="$1"

  sed -n '/^  cat <<'\''EOF'\'' >"\${DEV_HOME}\/\.local\/bin\/devbox-agent-limit-notify"$/,/^EOF$/p' \
    "$FEATURE_AGENT_NOTIFY" | sed '1d;$d' >"${dest_dir}/devbox-agent-limit-notify"

  sed -n '/^  cat <<'\''EOF'\'' >"\${DEV_HOME}\/\.local\/bin\/devbox-claude-limit-detect"$/,/^EOF$/p' \
    "$FEATURE_AGENT_NOTIFY" | sed '1d;$d' >"${dest_dir}/devbox-claude-limit-detect"

  sed -n '/^  cat <<'\''EOF'\'' >"\${DEV_HOME}\/\.local\/bin\/devbox-codex-limit-detect"$/,/^EOF$/p' \
    "$FEATURE_AGENT_NOTIFY" | sed '1d;$d' >"${dest_dir}/devbox-codex-limit-detect"

  local script
  for script in devbox-agent-limit-notify devbox-claude-limit-detect devbox-codex-limit-detect; do
    [[ -s "${dest_dir}/${script}" ]] || return 1
    chmod 0755 "${dest_dir}/${script}"
  done
}

# Runs the real, extracted scripts end to end against a stubbed `happy` CLI:
# a genuine limit notifies exactly once per dedup window, everything else
# (normal stops, other API errors, unrelated Codex turns, malformed input,
# no `happy` on PATH) must stay silent and must never fail the caller.
agent_limit_notify_scripts_behave_correctly() {
  local bin_dir="${TEST_TMP}/agent-notify-bin"
  local fake_home="${TEST_TMP}/agent-notify-home"
  local stub_dir="${TEST_TMP}/agent-notify-happy-stub"
  local calls="${TEST_TMP}/agent-notify-happy-calls"

  mkdir -p "$bin_dir" "${fake_home}/.local/bin" "${fake_home}/.config/devbox" "$stub_dir"
  extract_agent_limit_notify_scripts "$bin_dir" || return 1
  cp "${bin_dir}/"* "${fake_home}/.local/bin/"

  cat <<EOF >"${stub_dir}/happy"
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$calls"
EOF
  chmod 0755 "${stub_dir}/happy"

  run_with_stub() {
    HOME="$fake_home" \
      PATH="${stub_dir}:/usr/bin:/bin" \
      "$@"
  }

  # A genuine rate-limit StopFailure notifies once.
  : >"$calls"
  echo '{"error_type":"rate_limit"}' \
    | run_with_stub "${fake_home}/.local/bin/devbox-claude-limit-detect" || return 1
  [[ "$(wc -l <"$calls")" == "1" ]] || return 1
  grep -Fq -- '-t Claude-Limit erreicht' "$calls" || return 1

  # A second hit inside the dedup window does not notify again.
  echo '{"error_type":"rate_limit"}' \
    | run_with_stub "${fake_home}/.local/bin/devbox-claude-limit-detect" || return 1
  [[ "$(wc -l <"$calls")" == "1" ]] || return 1

  # A non-limit API error (e.g. overloaded) stays silent.
  : >"$calls"
  echo '{"error_type":"overloaded"}' \
    | run_with_stub "${fake_home}/.local/bin/devbox-claude-limit-detect" || return 1
  [[ ! -s "$calls" ]] || return 1

  # Malformed/empty stdin must not crash and must not notify.
  echo 'not json' | run_with_stub "${fake_home}/.local/bin/devbox-claude-limit-detect" || return 1
  [[ ! -s "$calls" ]] || return 1

  # Codex: an unambiguous limit phrase in the last assistant message notifies.
  : >"$calls"
  echo '{"last-assistant-message":"Sorry, I have hit my Usage Limit for now."}' \
    | run_with_stub "${fake_home}/.local/bin/devbox-codex-limit-detect" || return 1
  [[ "$(wc -l <"$calls")" == "1" ]] || return 1
  grep -Fq -- '-t Codex-Limit erreicht' "$calls" || return 1

  # An ordinary Codex turn stays silent.
  : >"$calls"
  echo '{"last-assistant-message":"I finished refactoring the module."}' \
    | run_with_stub "${fake_home}/.local/bin/devbox-codex-limit-detect" || return 1
  [[ ! -s "$calls" ]] || return 1

  # No `happy` on PATH: clean exit, no notification, no state written.
  # `command -v happy` is a shell builtin, so a PATH holding nothing but bash
  # keeps a `happy` that happens to be installed on the test host out of the
  # way (same technique as happy_daemon_guard_starts_only_a_paired_idle_daemon).
  local no_happy_dir="${TEST_TMP}/agent-notify-no-happy"
  mkdir -p "$no_happy_dir"
  ln -sf "$(command -v bash)" "${no_happy_dir}/bash"

  rm -f "${fake_home}/.config/devbox/agent-limit-notify.claude.state"
  HOME="$fake_home" \
    PATH="$no_happy_dir" \
    "${fake_home}/.local/bin/devbox-agent-limit-notify" claude || return 1
  [[ ! -f "${fake_home}/.config/devbox/agent-limit-notify.claude.state" ]]
}

extract_manager
normalize_continuations "$INSTALL_SCRIPT" >"$NORM_INSTALL"
normalize_continuations "$MANAGER" >"$NORM_MANAGER"
normalize_continuations "$LIB_USER" >"$NORM_LIB_USER"
normalize_continuations "$FEATURE_BASE" >"$NORM_FEATURE_BASE"
normalize_continuations "$FEATURE_POSTGRES" >"$NORM_FEATURE_POSTGRES"
normalize_continuations "$FEATURE_HAPPY" >"$NORM_FEATURE_HAPPY"
normalize_continuations "$FEATURE_KISUKE" >"$NORM_FEATURE_KISUKE"
normalize_continuations "$FEATURE_AGENT_NOTIFY" >"$NORM_FEATURE_AGENT_NOTIFY"
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
run_test "installer does not claim Ubuntu 20.04 support" installer_does_not_claim_ubuntu_20_04_support
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
run_test "Kisuke-aware remote instructions" remote_instructions_are_kisuke_aware
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
run_test "devbox version --json reports the manifest" devbox_version_json_reports_the_manifest
run_test "Multica external reverse proxy is restricted and uses token login" multica_external_reverse_proxy_is_restricted_and_uses_token_login
run_test "toolchain artifacts are checksum-verified" downloaded_toolchain_artifacts_are_checksum_verified
run_test "checksums.env matches embedded checksums" checksums_env_matches_embedded_checksums
run_test "complete stack validation" installer_validates_complete_stack
run_test "postgres package is a separate optional feature" postgres_package_is_a_separate_optional_feature
run_test "validation skips checks for disabled features" validation_skips_checks_for_disabled_features
run_test "install.sh records DevBox state" install_script_records_devbox_state
run_test "install.sh classifies active-ref mode" install_script_classifies_active_ref_mode
run_test "install.sh migrates legacy user-state features" install_script_migrates_legacy_user_state_features
run_test "doctor is feature-aware" doctor_is_feature_aware
run_test "devbox status composes existing status commands" devbox_status_composes_existing_status_commands
run_test "workspace list/doctor report project health read-only" workspace_list_and_doctor_report_project_health_read_only
run_test "doctor --json reports a valid summary matching the exit code" doctor_json_reports_a_valid_summary_matching_the_exit_code
run_test "write_root_owned_file refuses to follow a symlink" write_root_owned_file_refuses_to_follow_a_symlink
run_test "developer scaffold directories are symlink-guarded" developer_scaffold_dirs_are_symlink_guarded
run_test "ssh commands use symlink-safe writes" ssh_commands_use_symlink_safe_writes
run_test "postgres/elixir writes use the symlink-safe helper" postgres_and_elixir_writes_use_symlink_safe_helper
run_test "legacy previous-update state never executes file contents" migrate_legacy_previous_update_state_never_executes_file_contents
run_test "update and rollback round trip restores the active ref" update_and_rollback_round_trip_restores_the_active_ref
run_test "LXC integration test exercises the curl | bash path" lxc_integration_test_exercises_the_curl_pipe_path
run_test "install pins module fetches to a resolved commit" install_pins_module_fetches_to_a_resolved_commit
run_test "install falls back to the ref when resolution fails" install_falls_back_to_the_ref_when_resolution_fails
run_test "temp artifact downloads use unpredictable paths" temp_artifact_downloads_use_unpredictable_paths
run_test "postgres password reuse validates the persisted format" postgres_password_reuse_validates_the_persisted_format
run_test "postgres password is validated before SQL interpolation" postgres_password_is_validated_before_sql_interpolation
run_test "devbox version reports the installed commit" devbox_version_reports_the_installed_commit
run_test "update --check compares branch commits" update_check_compares_branch_commits
run_test "README pipe examples pass env vars to bash, not curl" readme_pipe_examples_pass_env_vars_to_bash_not_curl
run_test "shellcheck exceptions are not globally disabled" shellcheck_exceptions_are_not_globally_disabled
run_test "redis is a separate optional feature, disabled by default" redis_is_a_separate_optional_feature_disabled_by_default
run_test "redis validation and doctor are feature-aware" redis_validation_and_doctor_are_feature_aware
run_test "DEVBOX_REMOTE defaults to happy and validates input" devbox_remote_defaults_to_happy_and_validates_input
run_test "interactive Multica setup can collect reverse-proxy configuration" interactive_multica_setup_can_collect_reverse_proxy_configuration
run_test "install gates Happy installation on remote provider" install_gates_happy_installation_on_remote_provider
run_test "install gates Kisuke installation on remote provider" install_gates_kisuke_installation_on_remote_provider
run_test "remote provider is persisted and migrated as happy" remote_provider_is_persisted_and_migrated_as_happy
run_test "status/doctor are remote-provider aware" status_and_doctor_are_remote_provider_aware
run_test "update passes through the persisted remote provider" update_devbox_passes_through_the_persisted_remote_provider
run_test "doctor checks root state version" doctor_checks_root_state_version
run_test "Happy daemon starts at boot" happy_daemon_starts_at_boot
run_test "Happy .bashrc start remains a fallback" happy_bashrc_start_remains_as_fallback
run_test "Happy boot guard only starts a paired, idle daemon" happy_daemon_guard_starts_only_a_paired_idle_daemon
run_test "doctor checks the Happy daemon service" doctor_checks_happy_daemon_service
run_test "Kisuke gets a lingering user session" kisuke_gets_a_lingering_user_session_for_its_own_service_management
run_test "profile.d sets XDG_RUNTIME_DIR for sudo -iu shells" devbox_profile_sets_xdg_runtime_dir_for_sudo_iu_shells
run_test "Kisuke .bashrc start remains a fallback" kisuke_bashrc_start_remains_as_fallback
run_test "auth login uses kisuke connect, not bare login" auth_login_uses_kisuke_connect_not_bare_login
run_test "doctor checks the Kisuke daemon service" doctor_checks_kisuke_daemon_service
run_test "doctor --json reports Kisuke fields" doctor_json_reports_kisuke_fields
run_test "doctor stays healthy for a not-yet-configured Kisuke box" doctor_json_kisuke_not_yet_configured_is_still_healthy
run_test "agent limit-notify is installed and wired" agent_limit_notify_is_installed_and_wired
run_test "Claude settings hook merge is idempotent" claude_settings_hook_merge_is_idempotent
run_test "agent limit-notify scripts behave correctly" agent_limit_notify_scripts_behave_correctly

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
