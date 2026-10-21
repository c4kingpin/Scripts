#!/usr/bin/env bash
# Prüft die MIDI-Strecke vom Theater-PC über das Lekato USB-MIDI-Interface
# zum MA Lightcommander 12/2.

set -Eeuo pipefail

info() { printf '==> %s\n' "$*"; }
die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Verwendung: midi-check.sh [Optionen]

Ohne Optionen werden die vorhandenen MIDI-Ports aufgelistet. Mit --port wird
zusätzlich ein Control-Change gesendet, um eine Lightcommander-Memory
auszulösen.

Optionen:
  --list              Nur die MIDI-Ports auflisten (Standard)
  --port PORT         ALSA-Rohport, z. B. hw:1,0,0 (aus "amidi -l")
  --channel N         MIDI-Kanal 1-16 (Standard: 1)
  --cc N              Controller-Nummer 0-127 (Standard: 20)
  --value N           Controller-Wert 0-127 (Standard: 127)
  -h, --help          Diese Hilfe anzeigen

Beispiele:
  midi-check.sh --list
  midi-check.sh --port hw:1,0,0 --channel 1 --cc 20 --value 127

Controller-Nummer, Kanal und Wert stammen aus der MIDI-Tabelle des konkreten
Lightcommanders; dieses Skript kennt sie nicht.
EOF
}

list_ports() {
  command -v amidi >/dev/null 2>&1 || die "amidi fehlt. Installieren mit: sudo apt-get install alsa-utils"
  info "MIDI-Ports (amidi -l)"
  amidi -l || true
  if command -v aconnect >/dev/null 2>&1; then
    info "ALSA-Sequencer-Ziele (aconnect -l)"
    aconnect -l || true
  fi
}

require_byte() {
  local name="$1" value="$2" max="$3"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} muss eine Zahl sein: ${value}"
  (( value <= max )) || die "${name} muss zwischen 0 und ${max} liegen: ${value}"
}

PORT=""
CHANNEL=1
CONTROLLER=20
VALUE=127

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) shift ;;
    --port)
      [[ $# -ge 2 ]] || die "Für --port fehlt ein Wert."
      PORT="$2"
      shift 2
      ;;
    --channel)
      [[ $# -ge 2 ]] || die "Für --channel fehlt ein Wert."
      CHANNEL="$2"
      shift 2
      ;;
    --cc)
      [[ $# -ge 2 ]] || die "Für --cc fehlt ein Wert."
      CONTROLLER="$2"
      shift 2
      ;;
    --value)
      [[ $# -ge 2 ]] || die "Für --value fehlt ein Wert."
      VALUE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
done

# Werte zuerst prüfen, damit ein Tippfehler nicht erst nach der Portliste
# auffällt.
if [[ -n "$PORT" ]]; then
  [[ "$CHANNEL" =~ ^[0-9]+$ ]] || die "--channel muss eine Zahl sein: ${CHANNEL}"
  (( CHANNEL >= 1 && CHANNEL <= 16 )) || die "--channel muss zwischen 1 und 16 liegen: ${CHANNEL}"
  require_byte "--cc" "$CONTROLLER" 127
  require_byte "--value" "$VALUE" 127
fi

list_ports

[[ -n "$PORT" ]] || exit 0

# Control Change: Status 0xB0 + (Kanal - 1)
status=$(( 0xB0 + CHANNEL - 1 ))
message="$(printf '%02X %02X %02X' "$status" "$CONTROLLER" "$VALUE")"

info "Sende an ${PORT}: Kanal ${CHANNEL}, CC ${CONTROLLER} = ${VALUE} (${message})"
amidi -p "$PORT" -S "$message"
printf 'OK: Control-Change gesendet. Am Lightcommander prüfen, ob die Memory reagiert.\n'
