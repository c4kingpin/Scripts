#!/usr/bin/env bash
# Theater-PC installer for Ubuntu 26.04 LTS
# Installs Linux Show Player, Spotify, USB-MIDI support, and operating aids.
# With --kiosk it also enables autologin and hardens the machine for show use.

set -Eeuo pipefail
umask 022

readonly APP_ID="org.linuxshowplayer.LinuxShowPlayer"
readonly SCARLETT_GUI_REPOSITORY="https://github.com/geoffreybennett/alsa-scarlett-gui.git"
readonly SUPPORTED_RELEASE="26.04"
readonly GDM_CONFIG="/etc/gdm3/custom.conf"
readonly APT_HOLD_CONFIG="/etc/apt/apt.conf.d/99-theater-no-auto-upgrades"
readonly LOGIND_DROPIN="/etc/systemd/logind.conf.d/90-theater-kiosk.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

info() { printf '==> %s\n' "$*"; }
success() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARNUNG: %s\n' "$*" >&2; }
die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Verwendung: ./install.sh [Optionen]

Installiert die Theater-PC-Grundkonfiguration für Ubuntu 26.04 LTS.
Licht-Cues gehen über ein Lekato USB-MIDI-Interface an den MA Lightcommander
12/2, Audio über die vorhandene Soundkarte.

Optionen:
  --user NAME             Zielbenutzer (Standard: aufrufender Benutzer)
  --project NAME          Projektname (Standard: Stueck_2026)
  --upgrade-system        Vor der Installation ein vollständiges System-Upgrade ausführen
  --with-scarlett         Focusrite Scarlett 18i20 nutzen: alsa-scarlett-gui aus dem
                          Quellcode bauen (nur Audio; MIDI läuft über das Lekato)
  --skip-spotify          Spotify nicht als Snap installieren
  --skip-release-check    Nur warnen statt abbrechen, wenn das System nicht
                          Ubuntu 26.04 LTS ist
  --kiosk                 Showbetrieb einrichten: Autologin des Zielbenutzers,
                          automatische Updates stilllegen, Sperrbildschirm,
                          Crash-Dialoge und Datenträger-Fenster abschalten,
                          Linux Show Player automatisch starten
  -h, --help              Diese Hilfe anzeigen

Beispiel:
  ./install.sh --user theater --project Stueck_2026 --upgrade-system
  ./install.sh --user theater --kiosk

Achtung: --kiosk schließt Autologin ein. Der Rechner meldet sich danach ohne
Passwort an - wer physisch am Gerät ist, ist angemeldet. Das ist für einen
Theater-PC hinter verschlossener Tür gedacht, nicht für ein Gerät im Foyer.
Mit --kiosk bleiben außerdem Sicherheitsupdates bewusst liegen; sie müssen
zwischen zwei Produktionsserien von Hand eingespielt werden.

Das Skript richtet keine MIDI-Controllerwerte ein. Diese Werte sind von der
konkreten Hardware- und Show-Konfiguration abhängig und müssen anschließend
geprüft werden.
EOF
}

require_supported_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release fehlt."
  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "$SUPPORTED_RELEASE" ]]; then
    return 0
  fi

  local found="${ID:-unbekannt} ${VERSION_ID:-unbekannt}"
  if [[ "$SKIP_RELEASE_CHECK" == true ]]; then
    warn "Erwartet wird Ubuntu ${SUPPORTED_RELEASE} LTS, gefunden: ${found}. Fortsetzung auf eigenes Risiko."
    return 0
  fi

  die "Dieses Skript unterstützt ausschließlich Ubuntu ${SUPPORTED_RELEASE} LTS (gefunden: ${found}). Mit --skip-release-check überstimmen."
}

run_as_target() {
  sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" "$@"
}

# Ein zwischen GNOME-Versionen umbenanntes Schema oder ein nur mit GNOME
# Software vorhandener Key darf die Installation nicht abbrechen.
set_gsetting() {
  local schema="$1" key="$2" value="$3"

  if run_as_target gsettings writable "$schema" "$key" >/dev/null 2>&1; then
    run_as_target gsettings set "$schema" "$key" "$value"
  else
    warn "Einstellung ${schema} ${key} ist auf diesem System nicht vorhanden; übersprungen."
  fi
}

install_scarlett_gui() {
  local source_dir="${TARGET_HOME}/.local/src/alsa-scarlett-gui"

  info "Installiere Build-Abhängigkeiten für alsa-scarlett-gui"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    make gcc libgtk-4-dev libasound2-dev libssl-dev

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

install_spotify() {
  info "Installiere Spotify als Snap"
  if sudo snap list spotify >/dev/null 2>&1; then
    success "Spotify ist bereits installiert"
  else
    sudo snap install spotify
    success "Spotify installiert"
  fi
}

show_audio_outputs() {
  info "Prüfe Audioausgänge für Spotify und Linux Show Player"
  printf '%s\n' "ALSA-Geräte:"
  run_as_target aplay -l || info "Noch kein ALSA-Audiogerät erkannt; Soundkarte bitte anschließen."
  printf '%s\n' "PulseAudio/PipeWire-Ausgänge:"
  run_as_target pactl list short sinks || \
    info "Kein laufender Audio-Server erkannt; nach der Desktop-Anmeldung erneut prüfen."
}

# Das Lekato USB-MIDI-Interface ist class-compliant: snd-usb-audio bindet es
# ohne zusätzlichen Treiber. Nötig sind deshalb nur Gruppenmitgliedschaft,
# Zugriff des Flatpak-Sandbox auf /dev/snd und eine Sichtprüfung der Ports.
configure_midi() {
  info "Richte USB-MIDI-Zugriff für ${TARGET_USER} ein"

  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -Fqx audio; then
    success "${TARGET_USER} ist bereits in der Gruppe audio"
  else
    sudo usermod -aG audio "$TARGET_USER"
    info "${TARGET_USER} zur Gruppe audio hinzugefügt (wirkt nach neuer Anmeldung)"
  fi

  # Ohne --device=all sieht der Linux-Show-Player-Flatpak /dev/snd und damit
  # den ALSA-Sequencer nicht; das MIDI-Ausgabegerät fehlt dann im Programm.
  run_as_target flatpak override --user --device=all "$APP_ID"
  success "Flatpak-Zugriff auf Audio-/MIDI-Geräte freigegeben"

  info "Vorhandene MIDI-Ports"
  local ports
  if ports="$(amidi -l 2>/dev/null)" && grep -q '^\s*[IO]' <<<"$ports"; then
    printf '%s\n' "$ports"
  else
    warn "Es wurde kein MIDI-Port gefunden. Lekato-Interface anstecken und 'amidi -l' erneut ausführen."
  fi
}

create_project_tree() {
  local project_root="${TARGET_HOME}/Theater/${PROJECT_NAME}"

  info "Lege Projektstruktur unter ${project_root} an"
  run_as_target mkdir -p \
    "${project_root}/Show" \
    "${project_root}/Audio" \
    "${project_root}/Dokumentation" \
    "${project_root}/Backup" \
    "${project_root}/bin"

  info "Installiere midi-check.sh nach ${project_root}/bin"
  run_as_target install -m 0755 "${SCRIPT_DIR}/bin/midi-check.sh" \
    "${project_root}/bin/midi-check.sh"

  if ! run_as_target test -e "${project_root}/Dokumentation/Cue_Liste.md"; then
    run_as_target tee "${project_root}/Dokumentation/Cue_Liste.md" >/dev/null <<'EOF'
# Cue-Liste

| Cue | Name | Audio | Licht-Memory | MIDI-CC | Bemerkung |
| --- | --- | --- | --- | --- | --- |
| 001 | Einlass |  |  |  |  |
EOF
  fi

  if ! run_as_target test -e "${project_root}/Dokumentation/README.md"; then
    run_as_target tee "${project_root}/Dokumentation/README.md" >/dev/null <<'EOF'
# Inbetriebnahme

1. Lekato USB-MIDI-Interface anstecken und mit `amidi -l` sowie `aconnect -l`
   prüfen. Das OUT-Kabel des Interfaces geht in den MIDI IN des
   MA Lightcommander 12/2.
2. Audioausgabe prüfen (`aplay -l`, `pavucontrol`) und links/rechts auf das
   Tonmischpult legen.
3. Im Linux Show Player das Lekato-Interface als MIDI-Ausgabegerät und die
   gewünschte Soundkarte als Audioausgabe auswählen.
4. Jeden Licht-Cue als gezielten Aufruf einer Lightcommander-Memory per
   Control-Change anlegen, nicht als "nächster Schritt".
5. Licht und Ton für gemeinsame GO-Auslösung in einem parallelen Cue bündeln.
6. Vor jeder Vorstellung `bin/midi-check.sh --list` und einen Testaufruf der
   wichtigsten Memory ausführen.

Audio-Projektstandard: WAV, 48 kHz, 24 Bit.
EOF
  fi
}

configure_gnome_for_show() {
  info "Deaktiviere Energiesparen und Benachrichtigungsbanner für ${TARGET_USER}"
  set_gsetting org.gnome.desktop.session idle-delay 0
  set_gsetting org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
  set_gsetting org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
  set_gsetting org.gnome.desktop.notifications show-banners false
  set_gsetting org.gnome.desktop.notifications show-in-lock-screen false
}

configure_autologin() {
  if [[ ! -d /etc/gdm3 ]]; then
    warn "/etc/gdm3 fehlt - offenbar ist GDM nicht der Display-Manager. Autologin übersprungen; bitte von Hand einrichten."
    return 0
  fi

  if [[ ! -f "$GDM_CONFIG" ]]; then
    warn "${GDM_CONFIG} fehlt. Autologin übersprungen; bitte von Hand einrichten."
    return 0
  fi

  info "Richte Autologin für ${TARGET_USER} ein"
  sudo "${SCRIPT_DIR}/lib/gdm-autologin.sh" --file "$GDM_CONFIG" --user "$TARGET_USER"
  success "Autologin gesetzt (wirkt nach einem Neustart)"
}

# Alle Eingriffe landen in benannten Drop-ins oder haben eine Sicherung, damit
# sie sich einzeln zurücknehmen lassen; die Tabelle dazu steht in der README.
harden_for_kiosk() {
  info "Lege automatische Updates still"
  sudo tee "$APT_HOLD_CONFIG" >/dev/null <<'EOF'
// Theater-PC: keine unbeaufsichtigten Updates während einer Produktionsserie.
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
  sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || \
    warn "apt-daily-Timer konnten nicht deaktiviert werden; bitte prüfen."

  # Ohne Hold aktualisiert sich das Spotify-Snap mitten in der Serie.
  if sudo snap refresh --hold >/dev/null 2>&1; then
    success "Snap-Updates angehalten"
  else
    warn "'snap refresh --hold' nicht verfügbar (snapd zu alt?); Snap-Updates bleiben aktiv."
  fi

  set_gsetting org.gnome.software download-updates false
  set_gsetting org.gnome.software allow-updates false

  info "Deaktiviere Crash-Dialoge (apport)"
  sudo tee /etc/default/apport >/dev/null <<'EOF'
# Theater-PC: keine Crash-Dialoge über dem Show-Fenster.
enabled=0
EOF
  if systemctl list-unit-files apport.service >/dev/null 2>&1; then
    sudo systemctl disable --now apport.service || \
      warn "apport.service konnte nicht deaktiviert werden; bitte prüfen."
  fi

  info "Deaktiviere Sperrbildschirm und Bildschirmabdunklung"
  set_gsetting org.gnome.desktop.screensaver lock-enabled false
  set_gsetting org.gnome.desktop.screensaver idle-activation-enabled false
  set_gsetting org.gnome.desktop.lockdown disable-lock-screen true
  set_gsetting org.gnome.settings-daemon.plugins.power idle-dim false

  info "Sichere gegen Fehlgriffe am Gerät ab"
  set_gsetting org.gnome.settings-daemon.plugins.power power-button-action 'nothing'
  sudo mkdir -p "$(dirname "$LOGIND_DROPIN")"
  sudo tee "$LOGIND_DROPIN" >/dev/null <<'EOF'
# Theater-PC: Einschaltknopf auch vor der Anmeldung ignorieren.
[Login]
HandlePowerKey=ignore
EOF
  # Super+Alt+S wird im Betrieb versehentlich getroffen und schaltet sonst
  # mitten in der Vorstellung den Bildschirmleser ein.
  set_gsetting org.gnome.desktop.a11y.applications screen-reader-enabled false
  set_gsetting org.gnome.settings-daemon.plugins.media-keys screenreader "@as []"

  info "Unterdrücke Fenster beim Anstecken von Datenträgern"
  set_gsetting org.gnome.desktop.media-handling automount-open false
  set_gsetting org.gnome.desktop.media-handling autorun-never true

  success "Kiosk-Härtung abgeschlossen"
}

configure_player_autostart() {
  local autostart_dir="${TARGET_HOME}/.config/autostart"

  info "Richte Autostart für Linux Show Player ein"
  run_as_target mkdir -p "$autostart_dir"
  # Generierte Datei: wird bei jedem Lauf überschrieben. Ohne Showdatei - die
  # wählt der Operator.
  run_as_target tee "${autostart_dir}/${APP_ID}.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Linux Show Player
Exec=flatpak run ${APP_ID}
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
EOF
  success "Autostart eingerichtet"
}

TARGET_USER=""
PROJECT_NAME="Stueck_2026"
UPGRADE_SYSTEM=false
INSTALL_SCARLETT_GUI=false
INSTALL_SPOTIFY=true
SKIP_RELEASE_CHECK=false
KIOSK_MODE=false

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
    --with-scarlett) INSTALL_SCARLETT_GUI=true; shift ;;
    --skip-spotify) INSTALL_SPOTIFY=false; shift ;;
    --skip-release-check) SKIP_RELEASE_CHECK=true; shift ;;
    --kiosk) KIOSK_MODE=true; shift ;;
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

[[ -x "${SCRIPT_DIR}/bin/midi-check.sh" ]] || \
  die "${SCRIPT_DIR}/bin/midi-check.sh fehlt oder ist nicht ausführbar."

if [[ "$KIOSK_MODE" == true ]]; then
  [[ -x "${SCRIPT_DIR}/lib/gdm-autologin.sh" ]] || \
    die "${SCRIPT_DIR}/lib/gdm-autologin.sh fehlt oder ist nicht ausführbar."
fi

require_supported_release
sudo -v

info "Aktualisiere Paketlisten"
sudo apt-get update
if [[ "$UPGRADE_SYSTEM" == true ]]; then
  info "Führe vollständiges System-Upgrade aus"
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
fi

info "Installiere Grundwerkzeuge"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  flatpak snapd alsa-utils pulseaudio-utils pavucontrol git

info "Installiere Linux Show Player für ${TARGET_USER}"
run_as_target flatpak remote-add --user --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo
run_as_target flatpak install --user -y flathub "$APP_ID"

if [[ "$INSTALL_SPOTIFY" == true ]]; then
  install_spotify
  show_audio_outputs
fi

if [[ "$INSTALL_SCARLETT_GUI" == true ]]; then
  install_scarlett_gui
fi

configure_midi
create_project_tree
configure_gnome_for_show

if [[ "$KIOSK_MODE" == true ]]; then
  configure_autologin
  harden_for_kiosk
  configure_player_autostart
fi

success "Theater-PC-Grundinstallation abgeschlossen"
printf '\nNächste Schritte:\n'
step=1
printf '%s\n' "  ${step}. Lekato-Interface anschließen: amidi -l und aconnect -l"; step=$((step + 1))
printf '%s\n' "  ${step}. MIDI-Strecke testen: ${TARGET_HOME}/Theater/${PROJECT_NAME}/bin/midi-check.sh --list"; step=$((step + 1))
printf '%s\n' "  ${step}. Linux Show Player starten: flatpak run ${APP_ID}"; step=$((step + 1))
printf '%s\n' "  ${step}. Projektordner: ${TARGET_HOME}/Theater/${PROJECT_NAME}"; step=$((step + 1))
if [[ "$INSTALL_SCARLETT_GUI" == true ]]; then
  printf '%s\n' "  ${step}. Scarlett-Routing prüfen: alsa-scarlett-gui"; step=$((step + 1))
fi
if [[ "$KIOSK_MODE" == true ]]; then
  printf '%s\n' "  ${step}. Login-Keyring entsperren: in \"Passwörter und Schlüssel\" für den"
  printf '%s\n' "     Login-Keyring ein leeres Passwort setzen, sonst erscheint beim"
  printf '%s\n' "     Autologin ein Passwortdialog (Spotify legt dort seine Zugangsdaten ab)."; step=$((step + 1))
  printf '%s\n' "  ${step}. Neu starten und prüfen, dass die Anmeldung ohne Eingabe durchläuft."
fi
