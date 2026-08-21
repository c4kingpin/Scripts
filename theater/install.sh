#!/usr/bin/env bash
# Theater-PC installer for Ubuntu 24.04 LTS
# Installs Linux Show Player, Scarlett control software, and operating aids.

set -Eeuo pipefail
umask 022

readonly APP_ID="org.linuxshowplayer.LinuxShowPlayer"
readonly SCARLETT_GUI_REPOSITORY="https://github.com/geoffreybennett/alsa-scarlett-gui.git"

info() { printf '==> %s\n' "$*"; }
success() { printf 'OK: %s\n' "$*"; }
die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Verwendung: ./install.sh [Optionen]

Installiert die Theater-PC-Grundkonfiguration für Ubuntu 24.04.

Optionen:
  --user NAME             Zielbenutzer (Standard: aufrufender Benutzer)
  --project NAME          Projektname (Standard: Stueck_2026)
  --upgrade-system        Vor der Installation ein vollständiges System-Upgrade ausführen
  --skip-scarlett-gui     alsa-scarlett-gui nicht aus dem Quellcode bauen
  -h, --help              Diese Hilfe anzeigen

Beispiel:
  ./install.sh --user theater --project Stueck_2026 --upgrade-system

Das Skript richtet keine MIDI-Controllerwerte, kein Scarlett-Routing und keine
Autologin-Konfiguration ein. Diese Werte sind von der konkreten Hardware- und
Show-Konfiguration abhängig und müssen anschließend geprüft werden.
EOF
}

require_ubuntu_2404() {
  [[ -r /etc/os-release ]] || die "/etc/os-release fehlt."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
    die "Dieses Skript unterstützt ausschließlich Ubuntu 24.04 LTS."
}

run_as_target() {
  sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" "$@"
}

install_scarlett_gui() {
  local source_dir="${TARGET_HOME}/.local/src/alsa-scarlett-gui"

  info "Installiere alsa-scarlett-gui"
  run_as_target mkdir -p "${TARGET_HOME}/.local/src"

  if [[ -d "${source_dir}/.git" ]]; then
    info "Verwende vorhandenen alsa-scarlett-gui-Quellbaum: ${source_dir}"
  elif [[ -e "$source_dir" ]]; then
    die "${source_dir} existiert, ist aber kein Git-Repository; bitte manuell prüfen."
  else
    run_as_target git clone --depth 1 "$SCARLETT_GUI_REPOSITORY" "$source_dir"
  fi

  run_as_target make -C "${source_dir}/src" -j"$(nproc)"
  sudo make -C "${source_dir}/src" install
  success "alsa-scarlett-gui installiert"
}

create_project_tree() {
  local project_root="${TARGET_HOME}/Theater/${PROJECT_NAME}"

  info "Lege Projektstruktur unter ${project_root} an"
  run_as_target mkdir -p \
    "${project_root}/Show" \
    "${project_root}/Audio" \
    "${project_root}/Dokumentation" \
    "${project_root}/Backup"

  if ! run_as_target test -e "${project_root}/Dokumentation/Cue_Liste.md"; then
    run_as_target tee "${project_root}/Dokumentation/Cue_Liste.md" >/dev/null <<'EOF'
# Cue-Liste

| Cue | Name | Audio | Licht-Memory | Bemerkung |
| --- | --- | --- | --- | --- |
| 001 | Einlass |  |  |  |
EOF
  fi

  if ! run_as_target test -e "${project_root}/Dokumentation/README.md"; then
    run_as_target tee "${project_root}/Dokumentation/README.md" >/dev/null <<'EOF'
# Inbetriebnahme

1. Scarlett 18i20 direkt per USB anschließen und mit `aplay -l` sowie
   `aconnect -l` prüfen.
2. `alsa-scarlett-gui` öffnen und Playback 1/2 auf Line Output 1/2 routen.
3. Im Linux Show Player Scarlett als Audio- und MIDI-Ausgabegerät auswählen.
4. Scarlett MIDI OUT mit dem MIDI IN des MA Lightcommander 12/2 verbinden.
5. Jeden Licht-Cue als gezielten Aufruf einer Lightcommander-Memory anlegen,
   nicht als "nächster Schritt".
6. Licht und Ton für gemeinsame GO-Auslösung in einem parallelen Cue bündeln.

Audio-Projektstandard: WAV, 48 kHz, 24 Bit.
EOF
  fi
}

configure_gnome_for_show() {
  info "Deaktiviere Energiesparen und Benachrichtigungsbanner für ${TARGET_USER}"
  run_as_target gsettings set org.gnome.desktop.session idle-delay 0
  run_as_target gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
  run_as_target gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
  run_as_target gsettings set org.gnome.desktop.notifications show-banners false
  run_as_target gsettings set org.gnome.desktop.notifications show-in-lock-screen false
}

TARGET_USER=""
PROJECT_NAME="Stueck_2026"
UPGRADE_SYSTEM=false
INSTALL_SCARLETT_GUI=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || die "Für --user fehlt ein Wert."
      TARGET_USER="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die "Für --project fehlt ein Wert."
      PROJECT_NAME="$2"
      shift 2
      ;;
    --upgrade-system) UPGRADE_SYSTEM=true; shift ;;
    --skip-scarlett-gui) INSTALL_SCARLETT_GUI=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
done

if [[ -z "$TARGET_USER" ]]; then
  if [[ "${EUID}" -eq 0 ]]; then
    die "Bei einem Aufruf als root ist --user erforderlich."
  fi
  TARGET_USER="$USER"
fi

id "$TARGET_USER" >/dev/null 2>&1 || die "Benutzer ${TARGET_USER} existiert nicht."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Home-Verzeichnis von ${TARGET_USER} nicht gefunden."

require_ubuntu_2404
sudo -v

info "Aktualisiere Paketlisten"
sudo apt-get update
if [[ "$UPGRADE_SYSTEM" == true ]]; then
  info "Führe vollständiges System-Upgrade aus"
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
fi

info "Installiere Grundwerkzeuge"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  flatpak alsa-utils pavucontrol git make gcc libgtk-4-dev libasound2-dev libssl-dev

info "Installiere Linux Show Player für ${TARGET_USER}"
run_as_target flatpak remote-add --user --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo
run_as_target flatpak install --user -y flathub "$APP_ID"

if [[ "$INSTALL_SCARLETT_GUI" == true ]]; then
  install_scarlett_gui
fi

create_project_tree
configure_gnome_for_show

success "Theater-PC-Grundinstallation abgeschlossen"
printf '\nNächste Schritte:\n'
printf '%s\n' "  1. Scarlett anschließen: aplay -l und aconnect -l"
printf '%s\n' "  2. Routing prüfen: alsa-scarlett-gui"
printf '%s\n' "  3. Linux Show Player starten: flatpak run ${APP_ID}"
printf '%s\n' "  4. Projektordner: ${TARGET_HOME}/Theater/${PROJECT_NAME}"
