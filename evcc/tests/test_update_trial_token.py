#!/usr/bin/env python3
"""Regressionstests fuer evcc/update-trial-token.py.

Ohne Netzwerk und ohne systemd: HTTP-Zugriffe und `systemctl` werden durch
Attrappen ersetzt. Mit EVCC_LIVE_TEST=1 wird zusaetzlich die echte
evcc-Dokumentation abgefragt.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import stat
import sys
import tempfile
import time
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "update-trial-token.py"


def load_module():
    spec = importlib.util.spec_from_file_location("upd", SRC)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


m = load_module()
failures: list[str] = []
passed = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global passed
    print(("PASS " if condition else "FAIL ") + name +
          (f" :: {detail}" if detail and not condition else ""))
    if condition:
        passed += 1
    else:
        failures.append(name)


def b64(obj) -> str:
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def jwt(payload: dict | list) -> str:
    return f'{b64({"alg": "RS256", "typ": "JWT"})}.{b64(payload)}.sigxabc_123'


TRIAL_OLD = jwt({"iss": "evcc.io", "sub": "trial", "exp": 2000})
TRIAL_NEW = jwt({"iss": "evcc.io", "sub": "trial", "exp": 9000})
SPONSOR = jwt({"iss": "evcc.io", "sub": "sponsor", "exp": 9000})
EXPIRED = jwt({"iss": "evcc.io", "sub": "trial", "exp": 100})


def yml(line: str) -> str:
    return "site:\n  title: Home\n" + line + "\nloadpoints: []\n"


# --- JWT-Auswertung -------------------------------------------------------

check("JWT-Muster erkennt Testtoken", m.JWT_RE.fullmatch(TRIAL_OLD) is not None)
check("trial_expiry liest exp", m.trial_expiry(TRIAL_OLD) == 2000)

for desc, token in [("Sponsor-Token", SPONSOR), ("Unsinn", "not.a.jwt"),
                    ("exp als bool", jwt({"iss": "evcc.io", "sub": "trial", "exp": True})),
                    ("Payload kein Objekt", jwt(["a"]))]:
    try:
        m.trial_expiry(token)
        check(f"abgelehnt: {desc}", False)
    except m.UpdaterError:
        check(f"abgelehnt: {desc}", True)

# --- YAML-Zeilenerkennung -------------------------------------------------

for desc, line, expected in [
    ("einfach", f"sponsortoken: {TRIAL_OLD}", True),
    ("einfache Anfuehrungszeichen", f"sponsortoken: '{TRIAL_OLD}'", True),
    ("doppelte Anfuehrungszeichen", f'sponsortoken: "{TRIAL_OLD}"', True),
    ("mit Kommentar", f"sponsortoken: {TRIAL_OLD}  # trial", True),
    ("ohne Leerzeichen", f"sponsortoken:{TRIAL_OLD}", True),
    ("eingerueckt", f"  sponsortoken: {TRIAL_OLD}", False),
    ("leerer Wert", "sponsortoken:", False),
]:
    try:
        m.find_yaml_token(yml(line))
        found = True
    except m.UpdaterError:
        found = False
    check(f"YAML {desc}", found == expected)

try:
    m.find_yaml_token(yml(f"sponsortoken: {TRIAL_OLD}") + f"sponsortoken: {TRIAL_NEW}\n")
    check("doppelter Eintrag abgelehnt", False)
except m.UpdaterError as exc:
    check("doppelter Eintrag abgelehnt", "Mehrere" in str(exc), str(exc))

_, _, match, ending = m.find_yaml_token(
    f"site:\r\nsponsortoken: {TRIAL_OLD}\r\nloadpoints: []\r\n")
check("CRLF bleibt erhalten", ending == "\r\n" and match.group("token") == TRIAL_OLD)


# --- Attrappen fuer systemd und HTTP --------------------------------------

class Fake:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.active = True
        self.charging = False
        self.restart_ok = True
        self.doc_tokens = [TRIAL_NEW]
        self.api_keys: list[str | None] = []

    def systemctl(self, *args: str, timeout: int = 30, require_ok: bool = True) -> bool:
        self.calls.append(args)
        if args[0] == "is-active":
            return self.active
        if args[0] == "restart":
            if not self.restart_ok:
                self.active = False
                if require_ok:
                    raise m.UpdaterError("systemctl restart fehlgeschlagen: Attrappe")
                return False
            self.active = True
        return True

    def fetch_url(self, url: str, *, api_key: str | None = None, max_bytes: int = 0) -> bytes:
        if url == m.DOCS_URL:
            return ("<p>Testtoken</p>" + " ".join(self.doc_tokens)).encode()
        self.api_keys.append(api_key)
        power = 11000 if self.charging else 0
        return json.dumps({"result": {"loadpoints": [
            {"charging": self.charging, "chargePower": power}]}}).encode()


def setup(fake: Fake, content: str) -> Path:
    directory = Path(tempfile.mkdtemp())
    config = directory / "evcc.yaml"
    config.write_text(content)
    os.chmod(config, 0o640)
    m.systemctl = fake.systemctl
    m.fetch_url = fake.fetch_url
    return config


# Trockenlauf aendert nichts
fake = Fake()
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}  # trial"))
before = config.read_text()
check("Trockenlauf Rueckgabewert 0",
      m.run(config, m.DEFAULT_STATE_URL, None, True, now=1000) == 0)
check("Trockenlauf schreibt nicht", config.read_text() == before)
check("Trockenlauf ruehrt systemd nicht an", fake.calls == [], str(fake.calls))

# Echte Aktualisierung
fake = Fake()
original = yml(f"sponsortoken: {TRIAL_OLD}  # trial")
config = setup(fake, original)
check("Aktualisierung Rueckgabewert 0",
      m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000) == 0)
result = config.read_text()
check("Token getauscht", TRIAL_NEW in result and TRIAL_OLD not in result)
check("Kommentar erhalten", "# trial" in result)
check("uebrige YAML unveraendert", result.replace(TRIAL_NEW, TRIAL_OLD) == original)
check("evcc neu gestartet", ("restart", "evcc") in fake.calls)
backup = config.with_name(config.name + ".trial-updater.bak")
check("Backup enthaelt altes Token", backup.exists() and TRIAL_OLD in backup.read_text())
check("Backup mit 0600", stat.S_IMODE(backup.stat().st_mode) == 0o600,
      oct(stat.S_IMODE(backup.stat().st_mode)))
check("Dateirechte erhalten", stat.S_IMODE(config.stat().st_mode) == 0o640,
      oct(stat.S_IMODE(config.stat().st_mode)))
check("keine Temporaerdateien zurueck",
      [p.name for p in config.parent.iterdir() if p.name.startswith(".evcc")] == [])

# Sponsor-Token wird nie ersetzt
fake = Fake()
config = setup(fake, yml(f"sponsortoken: {SPONSOR}"))
before = config.read_text()
check("Sponsor-Token bleibt unangetastet",
      m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000) == 0
      and config.read_text() == before and fake.calls == [])

# Kein neueres Token
fake = Fake()
fake.doc_tokens = [TRIAL_OLD]
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
before = config.read_text()
check("gleiches Token, keine Aenderung",
      m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000) == 0
      and config.read_text() == before and fake.calls == [])

# Nur abgelaufene Tokens auf der Seite
fake = Fake()
fake.doc_tokens = [EXPIRED]
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
try:
    m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000)
    check("abgelaufenes Dokumenten-Token fuehrt zu Fehler", False)
except m.UpdaterError as exc:
    check("abgelaufenes Dokumenten-Token fuehrt zu Fehler",
          "kein noch gueltiges" in str(exc), str(exc))

# Aktiver Ladevorgang blockiert
fake = Fake()
fake.charging = True
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
before = config.read_text()
try:
    m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000)
    check("Ladevorgang blockiert", False)
except m.UpdaterError as exc:
    check("Ladevorgang blockiert", "laedt derzeit" in str(exc), str(exc))
check("Ladevorgang: Datei unveraendert", config.read_text() == before)

# Dienst nicht aktiv
fake = Fake()
fake.active = False
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
before = config.read_text()
try:
    m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000)
    check("inaktiver Dienst blockiert", False)
except m.UpdaterError as exc:
    check("inaktiver Dienst blockiert", "nicht aktiv" in str(exc), str(exc))
check("inaktiver Dienst: Datei unveraendert", config.read_text() == before)

# Neustartfehler -> Ruecknahme
fake = Fake()
fake.restart_ok = False
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}  # trial"))
before = config.read_text()
try:
    m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000)
    check("Neustartfehler fuehrt zu Fehler", False)
except m.UpdaterError:
    check("Neustartfehler fuehrt zu Fehler", True)
check("Ruecknahme stellt Original wieder her", config.read_text() == before,
      config.read_text()[:200])

# Nicht-lokale API wird abgelehnt
fake = Fake()
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
try:
    m.run(config, "https://evil.example/api/state", None, False, now=1000)
    check("entfernte API abgelehnt", False)
except m.UpdaterError as exc:
    check("entfernte API abgelehnt", "lokale HTTP-API" in str(exc), str(exc))

# Symlink wird abgelehnt
fake = Fake()
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
link = config.with_name("link.yaml")
link.symlink_to(config)
try:
    m.run(link, m.DEFAULT_STATE_URL, None, True, now=1000)
    check("Symlink abgelehnt", False)
except m.UpdaterError as exc:
    check("Symlink abgelehnt", "Symlinks" in str(exc), str(exc))

# Fehlender Eintrag (Konfiguration ueber die Weboberflaeche)
fake = Fake()
config = setup(fake, "site:\n  title: Home\n")
try:
    m.run(config, m.DEFAULT_STATE_URL, None, True, now=1000)
    check("fehlender Eintrag fuehrt zu Fehler", False)
except m.UpdaterError as exc:
    check("fehlender Eintrag fuehrt zu Fehler", "oberste" in str(exc), str(exc))

# API-Key wird weitergereicht
fake = Fake()
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
key_file = config.with_name("api.key")
key_file.write_text("evcc_geheim\n")
m.run(config, m.DEFAULT_STATE_URL, key_file, False, now=1000)
check("API-Key wird gesendet", fake.api_keys and all(k == "evcc_geheim" for k in fake.api_keys),
      str(fake.api_keys))

# Ungueltiger API-Key wird abgelehnt
fake = Fake()
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
key_file = config.with_name("api.key")
key_file.write_text("falsch\n")
try:
    m.run(config, m.DEFAULT_STATE_URL, key_file, False, now=1000)
    check("ungueltiger API-Key abgelehnt", False)
except m.UpdaterError as exc:
    check("ungueltiger API-Key abgelehnt", "evcc_" in str(exc), str(exc))

# Weiterleitung auf fremden Host (echte fetch_url-Implementierung)
isolated = load_module()


class FakeResponse:
    def geturl(self) -> str:
        return "https://evil.example/x"

    def read(self, _n: int) -> bytes:
        return b"{}"

    def __enter__(self):
        return self

    def __exit__(self, *_a):
        return False


isolated.urlopen = lambda req, timeout=0: FakeResponse()
try:
    isolated.fetch_url(isolated.DOCS_URL)
    check("Weiterleitung auf fremden Host abgelehnt", False)
except isolated.UpdaterError as exc:
    check("Weiterleitung auf fremden Host abgelehnt", "fremden Host" in str(exc), str(exc))

# Logausgaben enthalten nie ein Token
import io
import contextlib

fake = Fake()
config = setup(fake, yml(f"sponsortoken: {TRIAL_OLD}"))
buffer = io.StringIO()
with contextlib.redirect_stdout(buffer):
    m.run(config, m.DEFAULT_STATE_URL, None, False, now=1000)
printed = buffer.getvalue()
check("keine Tokens in der Logausgabe",
      TRIAL_OLD not in printed and TRIAL_NEW not in printed, printed)

# Optional: echte evcc-Dokumentation
if os.environ.get("EVCC_LIVE_TEST") == "1":
    live = load_module()
    try:
        _token, expiry = live.fetch_official_trial(now=int(time.time()))
        print(f"LIVE: Testtoken gefunden, gueltig bis {live.date_utc(expiry)}")
        check("LIVE: Testtoken auf docs.evcc.io gefunden", True)
    except live.UpdaterError as exc:
        check("LIVE: Testtoken auf docs.evcc.io gefunden", False, str(exc))

print()
if failures:
    print(f"FEHLGESCHLAGEN ({len(failures)}): " + ", ".join(failures))
    sys.exit(1)
print(f"Alle {passed} Tests bestanden.")
