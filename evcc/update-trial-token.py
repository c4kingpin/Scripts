#!/usr/bin/env python3
"""evcc-Testtoken-Aktualisierung fuer Linux/Raspberry Pi (YAML + systemd).

Nur fuer ein bereits vorhandenes, als `sub=trial` erkennbares Token in
/etc/evcc.yaml. Keine Drittanbieter-Pakete noetig.

Sicherheit:
- Quelle ausschliesslich offizielle evcc-Dokumentation per HTTPS
- Nur JWTs mit iss=evcc.io und sub=trial, keine abgelaufenen Tokens
- Nur Ersatz durch ein Token mit spaeterem Ablaufdatum
- Ein Sponsor-/Contributor-Token wird NIE ersetzt
- Kein Schreiben/Neustart solange evcc einen aktiven Ladevorgang meldet
- Backup + atomarer YAML-Tausch; Wiederherstellung bei Neustartfehler
- Keine JWT-Werte in Logausgaben

Die JWT-Signatur wird nicht lokal verifiziert (kein oeffentlicher Signaturschluessel).
Das Token stammt ueber HTTPS aus der offiziellen evcc-Dokumentation.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime as dt
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse
from urllib.request import Request, urlopen

DOCS_URL = "https://docs.evcc.io/de/sponsorship/"
DEFAULT_CONFIG = Path("/etc/evcc.yaml")
DEFAULT_STATE_URL = "http://127.0.0.1:7070/api/state"
JWT_PATTERN = r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"
JWT_RE = re.compile(r"(?<![A-Za-z0-9_-])" + JWT_PATTERN + r"(?![A-Za-z0-9_-])")
YAML_TOKEN_RE = re.compile(
    r"(?P<prefix>sponsortoken:[ \t]*)(?P<quote>['\"]?)"
    r"(?P<token>" + JWT_PATTERN + r")(?P=quote)"
    r"(?P<suffix>[ \t]*(?:#.*)?)"
)
MAX_DOC_BYTES = 2_000_000
HTTP_TIMEOUT = 15


class UpdaterError(Exception):
    """Erwartbarer Fehler (ohne Token-Anzeige)."""


def log(message: str) -> None:
    print(message, flush=True)


def date_utc(epoch: int) -> str:
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def claims(token: str) -> dict:
    if not re.fullmatch(JWT_PATTERN, token):
        raise UpdaterError("Ungueltiges JWT-Format.")
    try:
        payload = token.split(".")[1]
        decoded = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
        result = json.loads(decoded)
    except (ValueError, UnicodeDecodeError, binascii.Error) as exc:
        raise UpdaterError("JWT-Payload kann nicht gelesen werden.") from exc
    if not isinstance(result, dict):
        raise UpdaterError("JWT-Payload ist kein Objekt.")
    return result


def trial_expiry(token: str) -> int:
    info = claims(token)
    if info.get("iss") != "evcc.io" or info.get("sub") != "trial":
        raise UpdaterError("Token ist kein offizielles evcc-Testtoken.")
    exp = info.get("exp")
    if type(exp) is not int or exp <= 0:
        raise UpdaterError("Testtoken ohne gueltige Ablaufzeit.")
    return exp


def find_yaml_token(config_text: str) -> tuple[list[str], int, re.Match[str], str]:
    lines = config_text.splitlines(keepends=True)
    matches = [(i, line) for i, line in enumerate(lines)
               if line.startswith("sponsortoken:")]
    if len(matches) != 1:
        if not matches:
            raise UpdaterError(
                "Kein YAML-Eintrag 'sponsortoken:' in der obersten Ebene vorhanden. "
                "Bei evcc-Weboberflaechen-Konfiguration wird das Token in der DB "
                "verwaltet; dieses Skript darf sie nicht aendern."
            )
        raise UpdaterError("Mehrere sponsortoken-Eintraege in der YAML-Datei; Abbruch.")
    index, line = matches[0]
    ending = "\r\n" if line.endswith("\r\n") else ("\n" if line.endswith("\n") else "")
    match = YAML_TOKEN_RE.fullmatch(line[:len(line)-len(ending)] if ending else line)
    if not match:
        raise UpdaterError(
            "Die sponsortoken-Zeile hat ein unerwartetes Format. "
            "Erwartet: sponsortoken: <JWT> (optional in Anfuehrungszeichen)."
        )
    return lines, index, match, ending


def read_config(path: Path) -> tuple[str, os.stat_result]:
    try:
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode):
            raise UpdaterError("Konfigurationspfad ist keine normale Datei (Symlinks nicht erlaubt).")
        return path.read_bytes().decode("utf-8"), st
    except OSError as exc:
        raise UpdaterError(f"Konfiguration kann nicht gelesen werden: {exc.strerror}") from exc
    except UnicodeDecodeError as exc:
        raise UpdaterError("evcc.yaml ist keine UTF-8-Datei.") from exc


def fetch_url(url: str, *, api_key: str | None = None, max_bytes: int = MAX_DOC_BYTES) -> bytes:
    headers = {"User-Agent": "evcc-trial-updater/1.0", "Accept": "text/html,application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = Request(url, headers=headers)
    try:
        with urlopen(req, timeout=HTTP_TIMEOUT) as response:
            # Nie per Redirect an fremde Hosts weiterleiten.
            expected = urlparse(url)
            actual = urlparse(response.geturl())
            if (actual.scheme, actual.hostname) != (expected.scheme, expected.hostname):
                raise UpdaterError("HTTP-Weiterleitung auf einen fremden Host; Abbruch.")
            content = response.read(max_bytes + 1)
    except UpdaterError:
        raise
    except Exception as exc:
        raise UpdaterError(f"HTTP-Abfrage fehlgeschlagen: {type(exc).__name__}: {exc}") from exc
    if len(content) > max_bytes:
        raise UpdaterError("HTTP-Antwort zu gross; Abbruch.")
    return content


def fetch_official_trial(*, now: int) -> tuple[str, int]:
    html = fetch_url(DOCS_URL).decode("utf-8", errors="replace")
    possible = []
    for token in set(JWT_RE.findall(html)):
        try:
            exp = trial_expiry(token)
            if exp > now:
                possible.append((exp, token))
        except UpdaterError:
            continue
    if not possible:
        raise UpdaterError(
            "Auf der offiziellen evcc-Seite wurde kein noch gueltiges Testtoken gefunden. "
            "Evtl. ist das Token abgelaufen oder der Seitenaufbau wurde geaendert."
        )
    exp, token = max(possible)
    return token, exp


def can_restart_safely(state_url: str, api_key_file: Path | None = None) -> None:
    parsed = urlparse(state_url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise UpdaterError("Aus Sicherheitsgruenden ist nur eine lokale HTTP-API erlaubt.")
    api_key = None
    if api_key_file:
        try:
            api_key = api_key_file.read_text(encoding="utf-8").strip()
            if not api_key.startswith("evcc_"):
                raise UpdaterError("Die API-Key-Datei enthaelt keinen gueltigen evcc_-Schluessel.")
        except OSError as exc:
            raise UpdaterError("API-Key-Datei nicht lesbar.") from exc
    try:
        data = json.loads(fetch_url(state_url, api_key=api_key, max_bytes=500_000))
    except (ValueError, UnicodeDecodeError) as exc:
        raise UpdaterError("evcc-API liefert kein gueltiges JSON.") from exc
    state = data.get("result", data) if isinstance(data, dict) else None
    if not isinstance(state, dict) or not isinstance(state.get("loadpoints"), list):
        raise UpdaterError("evcc-API: Ladepunkt-Zustand nicht erkennbar; kein Neustart.")
    for item in state["loadpoints"]:
        if not isinstance(item, dict):
            raise UpdaterError("evcc-API: Unbekanntes Ladepunktformat; kein Neustart.")
        charging = item.get("charging")
        power = item.get("chargePower")
        if type(charging) is not bool:
            raise UpdaterError("evcc-API: Ladezustand fehlt; kein Neustart.")
        if charging or (type(power) in (int, float) and power > 100):
            raise UpdaterError("Ein Ladepunkt laedt derzeit. Aktualisierung wird verschoben.")
    log("evcc-API: Kein aktiver Ladevorgang erkannt.")


def systemctl(*args: str, timeout: int = 30, require_ok: bool = True) -> bool:
    try:
        result = subprocess.run(["systemctl", *args], capture_output=True, text=True,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UpdaterError(f"systemctl {args[0]} nicht ausfuehrbar.") from exc
    if require_ok and result.returncode != 0:
        raise UpdaterError(
            f"systemctl {args[0]} fehlgeschlagen: "
            f"{(result.stderr or result.stdout).strip()[:300]}"
        )
    return result.returncode == 0


def atomic_save(path: Path, data: bytes, old_stat: os.stat_result, mode: int | None = None) -> None:
    """Schreibt im selben Dateisystem mit fsync + os.replace."""
    perms = (stat.S_IMODE(old_stat.st_mode) if mode is None else mode)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            os.fchmod(f.fileno(), perms)
            if os.geteuid() == 0:
                os.fchown(f.fileno(), old_stat.st_uid, old_stat.st_gid)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        if hasattr(os, "O_DIRECTORY"):
            dfd = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def update_config(path: Path, original: str, old_stat: os.stat_result,
                  updated: str, state_url: str, api_key_file: Path | None) -> None:
    if not systemctl("is-active", "--quiet", "evcc", require_ok=False):
        raise UpdaterError("evcc-Dienst ist nicht aktiv; Konfiguration wird nicht geaendert.")
    can_restart_safely(state_url, api_key_file)
    backup = path.with_name(path.name + ".trial-updater.bak")
    # Backup mit restriktiven Rechten. Ein bestehender Backup-Symlink wird ersetzt, nicht verfolgt.
    atomic_save(backup, original.encode("utf-8"), old_stat, mode=0o600)
    log(f"Backup angelegt: {backup}")
    try:
        # Eingabe zwischen Lesen und Schreiben koennte von Dritten geaendert worden sein.
        if path.read_bytes().decode("utf-8") != original:
            raise UpdaterError("evcc.yaml wurde zwischenzeitlich geaendert; Abbruch.")
        atomic_save(path, updated.encode("utf-8"), old_stat)
        # Noch einmal unmittelbar vor dem Neustart pruefen. Sonst zurueckrollen.
        can_restart_safely(state_url, api_key_file)
        systemctl("restart", "evcc", timeout=60)
        if not systemctl("is-active", "--quiet", "evcc", require_ok=False):
            raise UpdaterError("evcc wurde nach Neustart nicht aktiv.")
        log("OK: Testtoken aktualisiert, evcc ist aktiv.")
    except Exception as exc:
        # Falls YAML schon modifiziert wurde, nach Moeglichkeit zurueckrollen.
        current_bytes = path.read_bytes()
        if current_bytes == updated.encode("utf-8"):
            atomic_save(path, original.encode("utf-8"), old_stat)
            log("Originalkonfiguration wiederhergestellt.")
            if not systemctl("is-active", "--quiet", "evcc", require_ok=False):
                try:
                    systemctl("restart", "evcc", timeout=60)
                except UpdaterError:
                    log("WARNUNG: Rueckstart von evcc fehlgeschlagen; manuell pruefen!")
        if isinstance(exc, UpdaterError):
            raise
        raise UpdaterError(f"Aktualisierung fehlgeschlagen: {type(exc).__name__}") from exc


def run(config: Path, state_url: str, api_key_file: Path | None, dry_run: bool,
        *, now: int | None = None) -> int:
    now = int(time.time()) if now is None else now
    original, st = read_config(config)
    lines, idx, match, ending = find_yaml_token(original)
    current = match.group("token")
    try:
        current_exp = trial_expiry(current)
    except UpdaterError as exc:
        # Sicheres Verhalten fuer bezahlte, unbekannte oder manuell manipulierte Tokens.
        log(f"Keine Aenderung: Bestehendes Token wird geschuetzt ({exc}).")
        return 0
    log(f"Derzeitiges Testtoken: gueltig bis {date_utc(current_exp)}.")
    new_token, new_exp = fetch_official_trial(now=now)
    log(f"Offizielles Testtoken: gueltig bis {date_utc(new_exp)}.")
    if new_exp <= current_exp or new_token == current:
        log("Keine Aenderung erforderlich.")
        return 0
    if dry_run:
        log("TROCKENLAUF: Neueres Token gefunden. Keine Datei geaendert, kein Neustart.")
        return 0
    # Formatierung, Kommentar und Zeilenumbrueche beibehalten.
    lines[idx] = (match.group("prefix") + match.group("quote") + new_token +
                  match.group("quote") + match.group("suffix") + ending)
    update_config(config, original, st, "".join(lines), state_url, api_key_file)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Offizielles evcc-Testtoken in YAML sicher aktualisieren")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                        help="YAML-Datei (Standard: /etc/evcc.yaml)")
    parser.add_argument("--state-url", default=DEFAULT_STATE_URL,
                        help="Lokale evcc-API (Standard: http://127.0.0.1:7070/api/state)")
    parser.add_argument("--api-key-file", type=Path, default=None,
                        help="Optional: Datei mit evcc API-Key fuer /api/state")
    parser.add_argument("--dry-run", action="store_true",
                        help="Pruefen ohne Schreiben oder Neustart")
    args = parser.parse_args()
    try:
        return run(args.config, args.state_url, args.api_key_file, args.dry_run)
    except UpdaterError as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
