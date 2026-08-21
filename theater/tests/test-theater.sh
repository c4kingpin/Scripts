#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
readonly INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

help_output="$(${INSTALL_SCRIPT} --help)" || fail "help can be shown"

grep -Fq 'Ubuntu 24.04' "$INSTALL_SCRIPT" || fail "Ubuntu 24.04 is required"
grep -Fq 'org.linuxshowplayer.LinuxShowPlayer' "$INSTALL_SCRIPT" || fail "Linux Show Player Flatpak ID is used"
grep -Fq 'snap install spotify' "$INSTALL_SCRIPT" || fail "Spotify Snap is installed"
grep -Fq 'alsa-scarlett-gui.git' "$INSTALL_SCRIPT" || fail "Scarlett GUI source is used"
grep -Fq 'idle-delay 0' "$INSTALL_SCRIPT" || fail "screen blanking is disabled"
grep -Fq -- '--upgrade-system' <<<"$help_output" || fail "upgrade option is documented"
grep -Fq -- '--skip-spotify' <<<"$help_output" || fail "Spotify option is documented"

printf 'ok - theater installer static checks\n'
