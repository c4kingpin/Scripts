#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../misc/build.func" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jörn Siedentopf (c4kingpin)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/openai/codex

if [[ -n "${CODEX_DEVBOX_SOURCE_URL:-}" ]]; then
  export COMMUNITY_SCRIPTS_URL="${CODEX_DEVBOX_SOURCE_URL%/}"

  _cs_fetch_text() {
    local relative_path="${1:?relative path required}"
    local source_url="https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main"

    if [[ "$relative_path" == "install/codex-devbox-install.sh" ]]; then
      source_url="$COMMUNITY_SCRIPTS_URL"
    fi

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "${source_url}/${relative_path}"
    else
      wget -qO- "${source_url}/${relative_path}"
    fi
  }
fi

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

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}The development environment is available at:${CL}"
echo -e "${TAB}${BGN}pct enter ${CTID}${CL}"
echo -e "${TAB}${BGN}sudo -iu dev${CL}"
echo -e "${TAB}${BGN}codex-devbox onboard${CL}"
echo -e "${INFO}${YW}Container address:${CL} ${BGN}${IP}${CL}"
