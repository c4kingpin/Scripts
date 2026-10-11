#!/usr/bin/env python3
"""evcc-Testtoken-Aktualisierung fuer Linux/Raspberry Pi (systemd).

Ersetzt ein bereits vorhandenes, als `sub=trial` erkennbares Token. Es werden
beide Konfigurationswege von evcc unterstuetzt und im Modus `auto` selbst
erkannt:

- YAML-Datei (traditionell), Standard /etc/evcc.yaml
- evcc-Datenbank (Konfiguration ueber die Weboberflaeche), Zugriff
  ausschliesslich ueber die offizielle CLI `evcc settings get/set`

Keine Drittanbieter-Pakete noetig.

Sicherheit:
- Quelle ausschliesslich offizielle evcc-Dokumentation per HTTPS
- Nur JWTs mit iss=evcc.io und sub=trial, keine abgelaufenen Tokens
- Nur Ersatz durch ein Token mit spaeterem Ablaufdatum
- Ein Sponsor-/Contributor-Token wird NIE ersetzt
- Kein Schreiben/Neustart solange evcc einen aktiven Ladevorgang meldet
- Backup + atomarer YAML-Tausch; Wiederherstellung bei Neustartfehler
- Im Datenbankmodus wird der Vorgaengerwert gemerkt und zurueckgeschrieben
- Datenbankzugriff als Dienstnutzer, damit keine root-eigenen SQLite-WAL-
  Seitendateien entstehen, die der evcc-Dienst nicht mehr beschreiben kann
- Keine JWT-Werte in Logausgaben, auch nicht aus Fremdprozess-Ausgaben

Die JWT-Signatur wird nicht lokal verifiziert (kein oeffentlicher Signaturschluessel).
Das Token stammt ueber HTTPS aus der offiziellen evcc-Dokumentation.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime as dt
import getpass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
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
# Pfad und Dienstnutzer stammen aus der systemd-Unit des offiziellen
# .deb-Pakets (Environment=EVCC_DATABASE_DSN=..., User=evcc).
DEFAULT_DATABASE = Path("/var/lib/evcc/evcc.db")
DEFAULT_SERVICE_USER = "evcc"
SERVICE_UNIT = "evcc"
# Gross-/Kleinschreibung ist entscheidend: evcc vergleicht Schluessel exakt
# (db/settings/setting.go: `s.Key == key`, keine Normalisierung) und liest
# ausschliesslich "sponsorToken" (core/keys/global.go). Ein Eintrag mit anderer
# Schreibweise wird stillschweigend nie gelesen.
SETTING_KEY = "sponsorToken"
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


def scrub(text: str) -> str:
    """Entfernt JWTs aus Fremdtext, bevor er in eine Meldung gelangt."""
    return JWT_RE.sub("<token>", text)


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


def systemctl_run(*args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(["systemctl", *args], capture_output=True, text=True,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UpdaterError(f"systemctl {args[0]} nicht ausfuehrbar.") from exc


def systemctl(*args: str, timeout: int = 30, require_ok: bool = True) -> bool:
    result = systemctl_run(*args, timeout=timeout)
    if require_ok and result.returncode != 0:
        detail = scrub((result.stderr or result.stdout).strip())[:300]
        raise UpdaterError(f"systemctl {args[0]} fehlgeschlagen: {detail}")
    return result.returncode == 0


def service_database() -> Path | None:
    """Liest EVCC_DATABASE_DSN aus der systemd-Unit des Dienstes."""
    result = systemctl_run("show", "-p", "Environment", SERVICE_UNIT)
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if not line.startswith("Environment="):
            continue
        for item in shlex.split(line[len("Environment="):]):
            key, _, value = item.partition("=")
            if key == "EVCC_DATABASE_DSN" and value:
                # Ein DSN darf Parameter tragen; nur der Pfad interessiert.
                return Path(value.split("?", 1)[0])
    return None


def privilege_prefix(run_as: str | None) -> list[str]:
    """Befehlspraefix, um als Dienstnutzer zu laufen.

    Der evcc-Dienst laeuft als eigener Nutzer und die SQLite-Datenbank steht im
    WAL-Modus. Ein Schreibzugriff als root wuerde `-wal`/`-shm`-Seitendateien
    anlegen, die root gehoeren und die der Dienst danach nicht mehr beschreiben
    kann. Deshalb wird der Nutzer gewechselt, sobald wir root sind.
    """
    if not run_as or os.geteuid() != 0:
        return []
    if run_as == getpass.getuser():
        return []
    if shutil.which("runuser"):
        return ["runuser", "-u", run_as, "--"]
    if shutil.which("sudo"):
        return ["sudo", "-n", "-u", run_as, "--"]
    raise UpdaterError(
        f"Weder runuser noch sudo vorhanden, um als '{run_as}' zu arbeiten."
    )


def evcc_cli(args: list[str], *, evcc_bin: str, run_as: str | None,
             timeout: int = 60) -> str:
    """Ruft die evcc-CLI auf und liefert deren stdout.

    Achtung: evcc schreibt seine INFO-Zeilen ebenfalls nach stdout, direkt
    zwischen die Nutzdaten. Der Aufrufer muss filtern.
    """
    command = privilege_prefix(run_as) + [evcc_bin, *args]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=timeout, check=False, stdin=subprocess.DEVNULL)
    except FileNotFoundError as exc:
        raise UpdaterError(
            f"'{evcc_bin}' nicht gefunden. Pfad mit --evcc-bin angeben."
        ) from exc
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UpdaterError(f"'{evcc_bin} {args[0]}' nicht ausfuehrbar.") from exc
    if result.returncode != 0:
        # stdout kann den bestehenden Token enthalten, stderr die Nutzung.
        detail = scrub((result.stderr or result.stdout).strip())[:300]
        raise UpdaterError(f"'evcc {' '.join(args[:2])}' fehlgeschlagen: {detail}")
    return result.stdout


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


class YamlBackend:
    """Token in einer evcc.yaml, zeilenweise und formaterhaltend getauscht."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.label = f"YAML-Datei {path}"
        self._original: str = ""
        self._stat: os.stat_result | None = None
        self._lines: list[str] = []
        self._index = -1
        self._match: re.Match[str] | None = None
        self._ending = ""
        self._written: bytes | None = None
        self._anchored = False

    def read_current(self) -> str:
        """Liest den Token und merkt beim ersten Aufruf den Rueckrollstand.

        Weitere Aufrufe liefern denselben Wert: der Anker fuers Zurueckrollen
        darf nicht durch ein erneutes Lesen verlorengehen.
        """
        if self._anchored:
            assert self._match is not None
            return self._match.group("token")
        self._original, self._stat = read_config(self.path)
        self._lines, self._index, self._match, self._ending = find_yaml_token(self._original)
        self._anchored = True
        return self._match.group("token")

    def current_value(self) -> str | None:
        """Liest den tatsaechlich hinterlegten Token, ohne den Anker zu setzen."""
        try:
            text, _ = read_config(self.path)
            _, _, match, _ = find_yaml_token(text)
        except UpdaterError:
            return None
        return match.group("token")

    def apply(self, new_token: str) -> None:
        assert self._match is not None and self._stat is not None
        backup = self.path.with_name(self.path.name + ".trial-updater.bak")
        # Restriktive Rechte. Ein bestehender Backup-Symlink wird ersetzt,
        # nicht verfolgt.
        atomic_save(backup, self._original.encode("utf-8"), self._stat, mode=0o600)
        log(f"Backup angelegt: {backup}")
        # Zwischen Lesen und Schreiben koennte von Dritten geaendert worden sein.
        if self.path.read_bytes().decode("utf-8") != self._original:
            raise UpdaterError("evcc.yaml wurde zwischenzeitlich geaendert; Abbruch.")
        match, lines = self._match, list(self._lines)
        # Formatierung, Kommentar und Zeilenumbrueche beibehalten.
        lines[self._index] = (match.group("prefix") + match.group("quote") + new_token +
                              match.group("quote") + match.group("suffix") + self._ending)
        self._written = "".join(lines).encode("utf-8")
        atomic_save(self.path, self._written, self._stat)

    def is_applied(self) -> bool:
        if self._written is None:
            return False
        try:
            return self.path.read_bytes() == self._written
        except OSError:
            return False



    def restore(self) -> None:
        assert self._stat is not None
        atomic_save(self.path, self._original.encode("utf-8"), self._stat)


class DatabaseBackend:
    """Token in der evcc-Datenbank, ueber die offizielle CLI verwaltet.

    Es wird bewusst nicht direkt auf die SQLite-Datei zugegriffen: Schema und
    Ablage sind kein zugesichertes Format, `evcc settings` ist die dokumentierte
    Schnittstelle.
    """

    def __init__(self, database: Path, evcc_bin: str, run_as: str | None) -> None:
        self.database = database
        self.evcc_bin = evcc_bin
        self.run_as = run_as
        self.label = f"evcc-Datenbank {database}"
        self._original: str = ""
        self._written: str | None = None
        self._anchored = False

    def _all_settings(self) -> dict[str, str]:
        output = evcc_cli(["settings", "get", "--database", str(self.database)],
                          evcc_bin=self.evcc_bin, run_as=self.run_as)
        values: dict[str, str] = {}
        for line in output.splitlines():
            # evcc mischt eigene Logzeilen (beginnen mit '[') in dieselbe Ausgabe.
            if line.startswith("["):
                continue
            key, separator, value = line.partition(":")
            if separator:
                values[key.strip()] = value.strip().strip("\"'")
        return values

    def _settings_get(self) -> str | None:
        values = self._all_settings()
        token = values.get(SETTING_KEY) or None
        # Eintraege mit abweichender Schreibweise liest evcc nie. Sie still zu
        # uebergehen wuerde genau den Fehler verschleiern, der sie erzeugt hat.
        strays = sorted(k for k in values
                        if k != SETTING_KEY and k.lower() == SETTING_KEY.lower())
        if strays:
            listed = ", ".join(repr(k) for k in strays)
            if token is None:
                raise UpdaterError(
                    f"Die Datenbank enthaelt {listed}, aber kein '{SETTING_KEY}'. "
                    f"evcc vergleicht Schluessel exakt und liest nur "
                    f"'{SETTING_KEY}' -- der vorhandene Eintrag ist wirkungslos. "
                    f"Entfernen und das Token in der Weboberflaeche eintragen."
                )
            log(f"WARNUNG: wirkungsloser Zusatzeintrag in der Datenbank: {listed}.")
        return token

    def _settings_set(self, token: str) -> None:
        # -f ist Pflicht: ohne das Flag fragt die CLI interaktiv nach und
        # bricht ohne Terminal mit FATAL ab.
        evcc_cli(["settings", "set", "--database", str(self.database), "-f",
                  SETTING_KEY, token], evcc_bin=self.evcc_bin, run_as=self.run_as)

    def read_current(self) -> str:
        """Wie bei YamlBackend: der Anker wird nur beim ersten Aufruf gesetzt."""
        if not self.database.exists():
            raise UpdaterError(
                f"Keine evcc-Datenbank unter {self.database}. "
                "Pfad mit --database angeben."
            )
        if self._anchored:
            return self._original
        token = self._settings_get()
        if token is None:
            raise UpdaterError(
                f"In der evcc-Datenbank ist kein '{SETTING_KEY}' gesetzt. "
                "Es gibt also kein Testtoken, das ersetzt werden koennte -- "
                "zuerst eines in der Weboberflaeche unter Sponsoring eintragen."
            )
        self._original = token
        self._anchored = True
        return token

    def current_value(self) -> str | None:
        """Liest den tatsaechlich hinterlegten Token, ohne den Anker zu setzen."""
        try:
            return self._settings_get()
        except UpdaterError:
            return None

    def apply(self, new_token: str) -> None:
        # Zwischen Lesen und Schreiben koennte die Weboberflaeche geaendert haben.
        if self._settings_get() != self._original:
            raise UpdaterError(
                "Das Token in der Datenbank hat sich zwischenzeitlich geaendert; "
                "Abbruch."
            )
        log("Vorheriges Token gemerkt; Rueckschreiben bei Fehler moeglich.")
        self._settings_set(new_token)
        self._written = new_token

    def is_applied(self) -> bool:
        if self._written is None:
            return False
        return self.current_value() == self._written

    def restore(self) -> None:
        self._settings_set(self._original)


def resolve_database(explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit
    from_unit = service_database()
    if from_unit is not None:
        log(f"Datenbankpfad aus der systemd-Unit: {from_unit}")
        return from_unit
    return DEFAULT_DATABASE


def choose_backend(mode: str, config: Path, database: Path | None,
                   evcc_bin: str, service_user: str | None):
    """Waehlt den Konfigurationsweg; `auto` erkennt ihn selbst."""
    if mode == "yaml":
        return YamlBackend(config)
    if mode == "db":
        return DatabaseBackend(resolve_database(database), evcc_bin, service_user)
    # auto: eine YAML-Datei mit sponsortoken-Eintrag gewinnt, sonst Datenbank.
    # evcc sucht laut CLI-Hilfe unter ~/evcc.yaml oder /etc/evcc.yaml; das Home
    # des Dienstnutzers ist beim .deb-Paket das Datenbankverzeichnis.
    candidates = [config, DEFAULT_DATABASE.parent / "evcc.yaml"]
    for candidate in candidates:
        if not candidate.exists():
            continue
        # Ein vorhandener, aber nicht lesbarer oder kein regulaerer Pfad ist ein
        # Abbruchgrund und darf nicht still zum Datenbankmodus fuehren.
        text, _ = read_config(candidate)
        try:
            find_yaml_token(text)
        except UpdaterError:
            # Datei vorhanden, aber ohne Token-Eintrag: dann entscheidet die
            # Datenbank.
            continue
        return YamlBackend(candidate)
    return DatabaseBackend(resolve_database(database), evcc_bin, service_user)


def apply_update(backend, new_token: str, state_url: str,
                 api_key_file: Path | None) -> None:
    if not systemctl("is-active", "--quiet", SERVICE_UNIT, require_ok=False):
        raise UpdaterError("evcc-Dienst ist nicht aktiv; Konfiguration wird nicht geaendert.")
    can_restart_safely(state_url, api_key_file)
    try:
        backend.apply(new_token)
        # Noch einmal unmittelbar vor dem Neustart pruefen. Sonst zurueckrollen.
        can_restart_safely(state_url, api_key_file)
        # Ein laufender evcc uebernimmt eine Aenderung nicht von selbst --
        # gemessen an evcc 0.317.1, Datenbankwert geaendert, Status unveraendert.
        systemctl("restart", SERVICE_UNIT, timeout=60)
        if not systemctl("is-active", "--quiet", SERVICE_UNIT, require_ok=False):
            raise UpdaterError("evcc wurde nach Neustart nicht aktiv.")
        log("OK: Testtoken aktualisiert, evcc ist aktiv.")
    except Exception as exc:
        # Falls schon geschrieben wurde, nach Moeglichkeit zurueckrollen.
        if backend.is_applied():
            try:
                backend.restore()
                log("Vorherige Konfiguration wiederhergestellt.")
            except UpdaterError:
                log("WARNUNG: Wiederherstellung fehlgeschlagen; manuell pruefen!")
            if not systemctl("is-active", "--quiet", SERVICE_UNIT, require_ok=False):
                try:
                    systemctl("restart", SERVICE_UNIT, timeout=60)
                except UpdaterError:
                    log("WARNUNG: Rueckstart von evcc fehlgeschlagen; manuell pruefen!")
        if isinstance(exc, UpdaterError):
            raise
        raise UpdaterError(f"Aktualisierung fehlgeschlagen: {type(exc).__name__}") from exc


def run(config: Path, state_url: str, api_key_file: Path | None, dry_run: bool,
        *, mode: str = "auto", database: Path | None = None,
        evcc_bin: str = "evcc", service_user: str | None = DEFAULT_SERVICE_USER,
        now: int | None = None) -> int:
    now = int(time.time()) if now is None else now
    backend = choose_backend(mode, config, database, evcc_bin, service_user)
    log(f"Konfigurationsquelle: {backend.label}")
    current = backend.read_current()
    try:
        current_exp = trial_expiry(current)
    except UpdaterError as exc:
        # Sicheres Verhalten fuer bezahlte, unbekannte oder manuell
        # manipulierte Tokens.
        log(f"Keine Aenderung: Bestehendes Token wird geschuetzt ({exc}).")
        return 0
    log(f"Derzeitiges Testtoken: gueltig bis {date_utc(current_exp)}.")
    new_token, new_exp = fetch_official_trial(now=now)
    log(f"Offizielles Testtoken: gueltig bis {date_utc(new_exp)}.")
    if new_exp <= current_exp or new_token == current:
        log("Keine Aenderung erforderlich.")
        return 0
    if dry_run:
        log("TROCKENLAUF: Neueres Token gefunden. Nichts geaendert, kein Neustart.")
        return 0
    apply_update(backend, new_token, state_url, api_key_file)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Offizielles evcc-Testtoken sicher aktualisieren "
                    "(YAML-Datei oder evcc-Datenbank)")
    parser.add_argument("--mode", choices=("auto", "yaml", "db"), default="auto",
                        help="Konfigurationsweg (Standard: auto erkennt ihn selbst)")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                        help="YAML-Datei (Standard: /etc/evcc.yaml)")
    parser.add_argument("--database", type=Path, default=None,
                        help="evcc-Datenbank; Standard aus der systemd-Unit, "
                             "sonst /var/lib/evcc/evcc.db")
    parser.add_argument("--evcc-bin", default="evcc",
                        help="Pfad zur evcc-CLI (Standard: evcc aus dem PATH)")
    parser.add_argument("--service-user", default=DEFAULT_SERVICE_USER,
                        help="Nutzer fuer den Datenbankzugriff (Standard: evcc); "
                             "leer laesst den Nutzer unveraendert")
    parser.add_argument("--state-url", default=DEFAULT_STATE_URL,
                        help="Lokale evcc-API (Standard: http://127.0.0.1:7070/api/state)")
    parser.add_argument("--api-key-file", type=Path, default=None,
                        help="Optional: Datei mit evcc API-Key fuer /api/state")
    parser.add_argument("--dry-run", action="store_true",
                        help="Pruefen ohne Schreiben oder Neustart")
    args = parser.parse_args()
    try:
        return run(args.config, args.state_url, args.api_key_file, args.dry_run,
                   mode=args.mode, database=args.database,
                   evcc_bin=args.evcc_bin,
                   service_user=args.service_user or None)
    except UpdaterError as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
