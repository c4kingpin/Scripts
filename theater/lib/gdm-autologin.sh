#!/usr/bin/env bash
# Setzt oder entfernt das GDM-Autologin in einer GDM-Konfigurationsdatei.
#
# /etc/gdm3/custom.conf kennt kein Drop-in-Verzeichnis, die Datei muss also
# in-place umgeschrieben werden. Die Logik liegt deshalb hier: so ist sie ohne
# root gegen eine Kopie testbar (siehe tests/test-theater.sh).

set -Eeuo pipefail

info() { printf '==> %s\n' "$*"; }
die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Verwendung: gdm-autologin.sh --file PFAD (--user NAME | --disable)

Schreibt AutomaticLoginEnable/AutomaticLogin im Abschnitt [daemon] einer
GDM-Konfigurationsdatei. Der Aufruf ist idempotent; vor der ersten Änderung
wird einmalig PFAD.theater-bak angelegt.

Optionen:
  --file PFAD      Zu bearbeitende Datei, z. B. /etc/gdm3/custom.conf
  --user NAME      Benutzer, der automatisch angemeldet wird
  --disable        Autologin abschalten (AutomaticLoginEnable=false)
  -h, --help       Diese Hilfe anzeigen

Beispiele:
  gdm-autologin.sh --file /etc/gdm3/custom.conf --user theater
  gdm-autologin.sh --file /etc/gdm3/custom.conf --disable
EOF
}

CONFIG_FILE=""
LOGIN_USER=""
MODE="enable"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || die "Für --file fehlt ein Wert."
      CONFIG_FILE="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || die "Für --user fehlt ein Wert."
      LOGIN_USER="$2"
      shift 2
      ;;
    --disable) MODE="disable"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
done

[[ -n "$CONFIG_FILE" ]] || die "--file ist erforderlich."
[[ -f "$CONFIG_FILE" ]] || die "${CONFIG_FILE} ist keine Datei."

if [[ "$MODE" == "enable" ]]; then
  [[ -n "$LOGIN_USER" ]] || die "--user ist erforderlich (oder --disable verwenden)."
  # Vor dem Schreiben in eine Systemdatei prüfen, dass der Name wirklich ein
  # Benutzername ist.
  [[ "$LOGIN_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || \
    die "Ungültiger Benutzername: ${LOGIN_USER}"
elif [[ -n "$LOGIN_USER" ]]; then
  die "--user und --disable schließen sich aus."
fi

backup="${CONFIG_FILE}.theater-bak"
if [[ -e "$backup" ]]; then
  info "Sicherung existiert bereits: ${backup}"
else
  cp -p "$CONFIG_FILE" "$backup"
  info "Sicherung angelegt: ${backup}"
fi

tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '${tmp}'" EXIT

# Vorhandene (auch auskommentierte) Autologin-Zeilen im Abschnitt [daemon]
# entfernen und die kanonischen Zeilen direkt hinter den Abschnittskopf
# setzen. Nur der erste [daemon]-Abschnitt bekommt sie, alles andere bleibt
# unverändert - dadurch ist ein zweiter Lauf byte-identisch.
awk -v mode="$MODE" -v login_user="$LOGIN_USER" '
function emit() {
  if (mode == "enable") {
    print "AutomaticLoginEnable=true"
    print "AutomaticLogin=" login_user
  } else {
    print "AutomaticLoginEnable=false"
  }
}
/^[[:space:]]*\[/ {
  if (tolower($0) ~ /^[[:space:]]*\[daemon\][[:space:]]*$/) {
    in_daemon = 1
    print
    if (!inserted) {
      emit()
      inserted = 1
    }
    next
  }
  in_daemon = 0
  print
  next
}
in_daemon && /^[[:space:]]*#?[[:space:]]*AutomaticLogin(Enable)?[[:space:]]*=/ { next }
{ print }
END {
  if (!inserted) {
    print "[daemon]"
    emit()
  }
}
' "$CONFIG_FILE" >"$tmp"

chmod --reference="$CONFIG_FILE" "$tmp"
chown --reference="$CONFIG_FILE" "$tmp" 2>/dev/null || true
mv "$tmp" "$CONFIG_FILE"
trap - EXIT

if [[ "$MODE" == "enable" ]]; then
  info "Autologin für ${LOGIN_USER} in ${CONFIG_FILE} gesetzt"
else
  info "Autologin in ${CONFIG_FILE} abgeschaltet"
fi
