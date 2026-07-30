#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jörn Siedentopf (c4kingpin)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openai/codex

readonly COMMUNITY_FRAMEWORK_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"

bootstrap_framework() {
  local local_build_func
  local build_func=""
  local upstream_install_base="${COMMUNITY_FRAMEWORK_URL}/install/"
  local source_install_base=""

  local_build_func="$(dirname "${BASH_SOURCE[0]}")/../misc/build.func"
  if [[ -r "$local_build_func" ]]; then
    source "$local_build_func"
  else
    if command -v curl >/dev/null 2>&1; then
      build_func="$(
        curl -fsSL --connect-timeout 10 --retry 5 --retry-connrefused \
          "${COMMUNITY_FRAMEWORK_URL}/misc/build.func"
      )" || build_func=""
    elif command -v wget >/dev/null 2>&1; then
      build_func="$(
        wget -qO- --tries=5 --timeout=10 \
          "${COMMUNITY_FRAMEWORK_URL}/misc/build.func"
      )" || build_func=""
    else
      echo "FATAL: Neither curl nor wget is available." >&2
      exit 115
    fi

    if [[ -z "$build_func" ]]; then
      echo "FATAL: Failed to download the Community Scripts framework." >&2
      exit 115
    fi

    if [[ -n "${CODEX_DEVBOX_SOURCE_URL:-}" ]]; then
      source_install_base="${CODEX_DEVBOX_SOURCE_URL%/}/install/"
      if [[ "$build_func" != *"$upstream_install_base"* ]]; then
        echo "FATAL: Community Scripts changed its installer download path." >&2
        exit 115
      fi
      build_func="${build_func//$upstream_install_base/$source_install_base}"
    fi

    source /dev/stdin <<<"$build_func"
  fi

  if ! declare -F build_container >/dev/null; then
    echo "FATAL: Community Scripts framework loaded incompletely." >&2
    exit 115
  fi
}

bootstrap_framework
unset -f bootstrap_framework

APP="Codex-DevBox"
var_tags="${var_tags:-ai;development;codex}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-32}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /usr/local/bin/codex-devbox ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  /usr/local/bin/codex-devbox update
  msg_ok "Updated successfully!"
  exit
}

select_codex_autonomy() {
  local choice=""
  local original_mode="${MODE:-default}"
  local requested="${var_codex_autonomy:-}"

  case "$requested" in
  controlled | balanced | autonomous | full-access)
    CODEX_AUTONOMY="$requested"
    ;;
  "")
    if [[ ! -t 0 ]] ||
      [[ "${PHS_SILENT:-0}" == "1" ]] ||
      [[ "${var_unattended:-}" =~ ^(yes|true|1)$ ]] ||
      [[ "${UNATTENDED:-}" =~ ^(yes|true|1)$ ]] ||
      [[ "${METHOD:-default}" =~ ^(mydefaults|appdefaults|generated)$ ]]; then
      CODEX_AUTONOMY="balanced"
    else
      MODE="advanced"
      choice="$(
        prompt_select \
          "How autonomously may Codex work?" \
          2 \
          120 \
          "Controlled - read-only; approve edits and commands" \
          "Balanced - edit workspace; approve external access (recommended)" \
          "Autonomous - workspace and network without approval prompts" \
          "Full access - no sandbox or prompts (LXC boundary only)"
      )"
      MODE="$original_mode"

      case "$choice" in
      Controlled*) CODEX_AUTONOMY="controlled" ;;
      Balanced*) CODEX_AUTONOMY="balanced" ;;
      Autonomous*) CODEX_AUTONOMY="autonomous" ;;
      "Full access"*) CODEX_AUTONOMY="full-access" ;;
      *) CODEX_AUTONOMY="balanced" ;;
      esac
    fi
    ;;
  *)
    msg_error "Invalid var_codex_autonomy: ${requested}"
    exit 1
    ;;
  esac

  export CODEX_AUTONOMY
  msg_ok "Codex autonomy profile: ${CODEX_AUTONOMY}"
}

start
select_codex_autonomy
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}The development environment is available at:${CL}"
echo -e "${TAB}${BGN}pct enter ${CTID}${CL}"
echo -e "${TAB}${BGN}sudo -iu dev${CL}"
echo -e "${TAB}${BGN}codex-devbox onboard${CL}"
echo -e "${INFO}${YW}Container address:${CL} ${BGN}${IP}${CL}"
