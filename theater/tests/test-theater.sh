#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
readonly INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"
readonly MIDI_CHECK="${PROJECT_ROOT}/bin/midi-check.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
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

printf 'ok - theater installer static checks\n'
