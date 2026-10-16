#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
readonly INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"
readonly MIDI_CHECK="${PROJECT_ROOT}/bin/midi-check.sh"
readonly GDM_AUTOLOGIN="${PROJECT_ROOT}/lib/gdm-autologin.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
trap 'rm -rf "$WORK_DIR"' EXIT

# Entspricht der von Ubuntu ausgelieferten Datei: die Autologin-Keys sind
# vorhanden, aber auskommentiert.
write_default_gdm_config() {
  cat >"$1" <<'EOF'
# GDM configuration storage

[daemon]
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false
# Enabling automatic login
#  AutomaticLoginEnable = true
#  AutomaticLogin = user1

[security]

[xdmcp]
EOF
}

help_output="$(${INSTALL_SCRIPT} --help)" || fail "help can be shown"

grep -Fq 'Ubuntu 26.04' "$INSTALL_SCRIPT" || fail "Ubuntu 26.04 is required"
grep -Fq '26.04' <<<"$help_output" || fail "the supported release is documented"
grep -Fq 'org.linuxshowplayer.LinuxShowPlayer' "$INSTALL_SCRIPT" || fail "Linux Show Player Flatpak ID is used"
grep -Fq 'snap install spotify' "$INSTALL_SCRIPT" || fail "Spotify Snap is installed"
grep -Fq 'pulseaudio-utils' "$INSTALL_SCRIPT" || fail "audio diagnostics are installed"
grep -Fq 'pactl list short sinks' "$INSTALL_SCRIPT" || fail "audio outputs are checked"
grep -Fq 'alsa-scarlett-gui.git' "$INSTALL_SCRIPT" || fail "Scarlett GUI source is used"
grep -Fq 'idle-delay 0' "$INSTALL_SCRIPT" || fail "screen blanking is disabled"

# The Lekato USB-MIDI interface is now the light-cue path, so MIDI access must
# be configured and the Flatpak sandbox must reach /dev/snd.
grep -Fq 'flatpak override --user --device=all' "$INSTALL_SCRIPT" || fail "Flatpak gets access to MIDI devices"
grep -Fq 'amidi -l' "$INSTALL_SCRIPT" || fail "MIDI ports are listed during installation"
grep -Fq 'usermod -aG audio' "$INSTALL_SCRIPT" || fail "the target user joins the audio group"

grep -Fq -- '--upgrade-system' <<<"$help_output" || fail "upgrade option is documented"
grep -Fq -- '--skip-spotify' <<<"$help_output" || fail "Spotify option is documented"
grep -Fq -- '--with-scarlett' <<<"$help_output" || fail "Scarlett opt-in is documented"
grep -Fq -- '--skip-release-check' <<<"$help_output" || fail "release check override is documented"
grep -Fq -- '--skip-scarlett-gui' "$INSTALL_SCRIPT" && fail "the removed Scarlett opt-out is gone"

# Scarlett is opt-in: its build dependencies must not be part of the base
# package set.
grep -Fq 'libgtk-4-dev' "$INSTALL_SCRIPT" || fail "Scarlett build dependencies are installed on demand"
install_line="$(grep -F 'flatpak snapd alsa-utils' "$INSTALL_SCRIPT")" || fail "base packages are installed"
grep -Fq 'libgtk-4-dev' <<<"$install_line" && fail "base packages stay free of Scarlett build dependencies"

[[ -x "$MIDI_CHECK" ]] || fail "midi-check.sh is executable"
bash -n "$MIDI_CHECK" || fail "midi-check.sh is syntactically valid"
midi_help="$("$MIDI_CHECK" --help)" || fail "midi-check.sh help can be shown"
grep -Fq -- '--port' <<<"$midi_help" || fail "midi-check.sh documents --port"
grep -Fq -- '--cc' <<<"$midi_help" || fail "midi-check.sh documents --cc"
grep -Fq 'amidi -p' "$MIDI_CHECK" || fail "midi-check.sh sends raw MIDI with amidi"

# Kiosk mode must stay opt-in: an unattended run must not enable autologin.
grep -Fq 'KIOSK_MODE=false' "$INSTALL_SCRIPT" || fail "kiosk mode is off by default"
grep -Fq -- '--kiosk' <<<"$help_output" || fail "kiosk option is documented"
grep -Fq 'Autologin' <<<"$help_output" || fail "the help warns that --kiosk includes autologin"
grep -Fq '99-theater-no-auto-upgrades' "$INSTALL_SCRIPT" || fail "automatic apt upgrades are held in a named drop-in"
grep -Fq 'apt-daily.timer' "$INSTALL_SCRIPT" || fail "apt-daily timers are disabled"
grep -Fq 'snap refresh --hold' "$INSTALL_SCRIPT" || fail "snap refreshes are held"
grep -Fq '/etc/default/apport' "$INSTALL_SCRIPT" || fail "apport crash dialogs are disabled"
grep -Fq 'lock-enabled false' "$INSTALL_SCRIPT" || fail "the lock screen is disabled"
grep -Fq "power-button-action 'nothing'" "$INSTALL_SCRIPT" || fail "the power button is neutralised"
grep -Fq 'HandlePowerKey=ignore' "$INSTALL_SCRIPT" || fail "logind ignores the power key"
grep -Fq 'screen-reader-enabled false' "$INSTALL_SCRIPT" || fail "the screen reader shortcut is disabled"
grep -Fq 'autorun-never true' "$INSTALL_SCRIPT" || fail "removable media windows are suppressed"
grep -Fq '.config/autostart' "$INSTALL_SCRIPT" || fail "the player is started automatically"

printf 'ok - theater installer static checks\n'

# gdm-autologin.sh rewrites a system file in place, so it is exercised for real
# against copies in a temporary directory.
[[ -x "$GDM_AUTOLOGIN" ]] || fail "gdm-autologin.sh is executable"
"$GDM_AUTOLOGIN" --help >/dev/null || fail "gdm-autologin.sh help can be shown"

config="${WORK_DIR}/custom.conf"
write_default_gdm_config "$config"
cp "$config" "${WORK_DIR}/original"

"$GDM_AUTOLOGIN" --file "$config" --user theater >/dev/null || fail "autologin can be enabled"
[[ "$(grep -c '^AutomaticLoginEnable=true$' "$config")" == 1 ]] || fail "AutomaticLoginEnable is set exactly once"
[[ "$(grep -c '^AutomaticLogin=theater$' "$config")" == 1 ]] || fail "AutomaticLogin names the target user exactly once"
grep -q '^#  AutomaticLogin' "$config" && fail "the commented-out defaults are removed"

# The keys must land inside [daemon], not in a later section.
daemon_block="$(awk '/^\[daemon\]$/{f=1;next} /^\[/{f=0} f' "$config")"
grep -Fq 'AutomaticLogin=theater' <<<"$daemon_block" || fail "the keys are written inside the [daemon] section"
grep -Fq '[security]' "$config" || fail "unrelated sections survive"

cmp -s "${WORK_DIR}/original" "${config}.theater-bak" || fail "the backup matches the original file"

cp "$config" "${WORK_DIR}/first-run"
"$GDM_AUTOLOGIN" --file "$config" --user theater >/dev/null || fail "a second run succeeds"
cmp -s "${WORK_DIR}/first-run" "$config" || fail "a second run is byte-identical"
cmp -s "${WORK_DIR}/original" "${config}.theater-bak" || fail "the backup is not overwritten on a second run"

"$GDM_AUTOLOGIN" --file "$config" --disable >/dev/null || fail "autologin can be disabled"
grep -q '^AutomaticLoginEnable=false$' "$config" || fail "disabling sets AutomaticLoginEnable=false"
grep -q '^AutomaticLogin=' "$config" && fail "disabling drops the AutomaticLogin line"

no_daemon="${WORK_DIR}/no-daemon.conf"
printf '[security]\nfoo=bar\n' >"$no_daemon"
"$GDM_AUTOLOGIN" --file "$no_daemon" --user theater >/dev/null || fail "a missing [daemon] section is handled"
grep -q '^\[daemon\]$' "$no_daemon" || fail "the [daemon] section is created"
grep -Fq 'foo=bar' "$no_daemon" || fail "existing keys survive when [daemon] is appended"

# A rejected user name must leave the file untouched.
guard="${WORK_DIR}/guard.conf"
write_default_gdm_config "$guard"
cp "$guard" "${WORK_DIR}/guard-original"
"$GDM_AUTOLOGIN" --file "$guard" --user 'a b;rm -rf /' >/dev/null 2>&1 && fail "an invalid user name is rejected"
cmp -s "${WORK_DIR}/guard-original" "$guard" || fail "a rejected user name leaves the file unchanged"
"$GDM_AUTOLOGIN" --file "$guard" --user theater --disable >/dev/null 2>&1 && fail "--user and --disable are mutually exclusive"
"$GDM_AUTOLOGIN" --file "${WORK_DIR}/missing.conf" --user theater >/dev/null 2>&1 && fail "a missing file is rejected"

printf 'ok - gdm autologin helper\n'
