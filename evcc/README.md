# evcc – Testtoken-Aktualisierung (Raspberry Pi)

[`update-trial-token.py`](update-trial-token.py) ersetzt das offizielle
evcc-**Testtoken** in `/etc/evcc.yaml` durch das aktuelle Token aus der
[evcc-Dokumentation](https://docs.evcc.io/de/sponsorship/) und startet den
Dienst neu. Reine Python-Standardbibliothek – keine zusätzlichen Pakete.

Hintergrund: Das Testtoken ist absichtlich kurzlebig und wird von evcc in
unregelmäßigen Abständen erneuert. Läuft es ab, fallen die Sponsor-Funktionen
aus, bis das Token von Hand ersetzt wird. Genau diesen Handgriff automatisiert
das Skript – und zwar so, dass es im Zweifelsfall lieber nichts tut.

> **Status:** Die Regressionstests laufen durch und die Tokenquelle ist live
> gegen `docs.evcc.io` geprüft. Ein Durchlauf auf echter Hardware mit laufendem
> evcc-Dienst steht noch aus – zuerst `--dry-run` verwenden.

## Voraussetzungen

- evcc per `apt`/`.deb` installiert und als systemd-Dienst `evcc` aktiv
- Konfiguration in einer **YAML-Datei** mit `sponsortoken:` auf oberster Ebene
- Ein bereits vorhandenes **Testtoken** in dieser Datei
- Python 3 aus der Distribution; die Raspberry-Pi-OS-Versionen Bullseye (3.9)
  und Bookworm (3.11) erfüllen das. Entwickelt und getestet wurde mit 3.12.
- Schreibrechte auf `/etc/evcc.yaml` und das Recht, `evcc` neu zu starten –
  praktisch also `sudo`

## Was das Skript *nicht* macht

- **evcc installieren oder aktualisieren.** Es setzt eine laufende Installation
  voraus und berührt nur die eine YAML-Zeile.
- **Ein Sponsor- oder Contributor-Token anfassen.** Erkennt es im `sub`-Feld
  etwas anderes als `trial`, bricht es mit Rückgabewert `0` ab und lässt die
  Datei unberührt. Ein bezahltes Token kann so nicht versehentlich durch ein
  Testtoken ersetzt werden.
- **Die Konfiguration aus der Weboberfläche ändern.** Wer evcc über die
  Weboberfläche konfiguriert hat, hat das Token in der evcc-Datenbank, nicht in
  der YAML-Datei. Das Skript findet dann keinen `sponsortoken:`-Eintrag und
  bricht mit einer entsprechenden Meldung ab, statt an der Datenbank zu
  arbeiten.
- **Die JWT-Signatur prüfen.** Es gibt keinen öffentlichen Signaturschlüssel.
  Das Vertrauen stützt sich auf TLS zu `docs.evcc.io` – siehe
  [Sicherheitszusagen](#sicherheitszusagen).

## Verwendung

```bash
sudo ./update-trial-token.py --dry-run        # nur prüfen
sudo ./update-trial-token.py                  # tatsächlich aktualisieren
```

| Option | Standard | Zweck |
| --- | --- | --- |
| `--config` | `/etc/evcc.yaml` | Pfad zur YAML-Konfiguration |
| `--state-url` | `http://127.0.0.1:7070/api/state` | lokale evcc-API; nur `127.0.0.1`, `localhost`, `::1` erlaubt |
| `--api-key-file` | – | Datei mit einem `evcc_…`-API-Key, falls die API geschützt ist |
| `--dry-run` | – | prüfen, ohne zu schreiben oder neu zu starten |

Rückgabewert `0` bei Erfolg **oder** wenn keine Änderung nötig war, `1` bei
Fehlern. Für einen systemd-Timer heißt das: `0` ist der Normalfall, `1` ist ein
Fall für `journalctl`.

### Typische Meldungen

| Meldung | Bedeutung |
| --- | --- |
| `Keine Aenderung erforderlich.` | Das Token in der Datei ist schon so neu wie das offizielle. Normalfall. |
| `Keine Aenderung: Bestehendes Token wird geschuetzt (…)` | Kein Testtoken in der Datei – vermutlich ein Sponsor-Token. Gewolltes Verhalten. |
| `Ein Ladepunkt laedt derzeit. Aktualisierung wird verschoben.` | Kein Eingriff während eines Ladevorgangs; beim nächsten Timer-Lauf erneut versuchen. |
| `Kein YAML-Eintrag 'sponsortoken:' …` | Konfiguration über die Weboberfläche, oder der Eintrag ist eingerückt. |
| `Auf der offiziellen evcc-Seite wurde kein noch gueltiges Testtoken gefunden.` | Entweder ist das Doku-Token abgelaufen, oder der Seitenaufbau hat sich geändert. |
| `evcc wurde nach Neustart nicht aktiv.` | Die Originaldatei wurde zurückgerollt – `journalctl -u evcc` prüfen. |

## Sicherheitszusagen

Jeder Punkt ist durch einen Test in [`tests/`](tests) abgedeckt:

- Tokenquelle ausschließlich `https://docs.evcc.io` – eine HTTP-Weiterleitung
  auf einen fremden Host bricht ab.
- Akzeptiert nur JWTs mit `iss=evcc.io` **und** `sub=trial`, nur unverfallen.
- **Sponsor- und Contributor-Tokens werden nie ersetzt** – ebenso kein Token,
  dessen Ablaufdatum nicht später liegt als das bestehende.
- Kein Schreiben und kein Neustart, solange die evcc-API einen aktiven
  Ladevorgang meldet – geprüft vor dem Schreiben **und** direkt vor dem
  Neustart.
- Backup nach `/etc/evcc.yaml.trial-updater.bak` mit Rechten `0600`; der
  Tausch erfolgt atomar (`fsync` + `os.replace`), Eigentümer und Rechte der
  Konfiguration bleiben erhalten.
- Scheitert der Neustart, wird die Originaldatei wiederhergestellt.
- Wurde die Datei zwischen Lesen und Schreiben von anderer Seite verändert,
  bricht das Skript ab, statt die fremde Änderung zu überschreiben.
- Symlinks als Konfigurationspfad werden abgelehnt; mehrere oder eingerückte
  `sponsortoken`-Einträge führen zum Abbruch statt zu einer falschen Änderung.
- Kommentar, Anführungszeichen und Zeilenenden der Zeile bleiben unverändert.
- Es landet nie ein JWT in der Logausgabe – auch nicht in Fehlermeldungen.

## Regelmäßig ausführen (systemd-Timer)

Das Doku-Token ist typischerweise nur wenige Tage gültig. Der Timer sollte
deshalb **täglich** laufen, nicht wöchentlich – sonst ist das geholte Token
beim nächsten Lauf schon wieder abgelaufen. `Persistent=true` holt einen Lauf
nach, der verpasst wurde, weil der Pi aus war.

```ini
# /etc/systemd/system/evcc-trial-token.service
[Unit]
Description=evcc-Testtoken aktualisieren
After=network-online.target evcc.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-trial-token.py
```

```ini
# /etc/systemd/system/evcc-trial-token.timer
[Unit]
Description=evcc-Testtoken taeglich pruefen

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
```

`RandomizedDelaySec` verteilt die Abfragen; die evcc-Doku wird nicht von allen
Installationen zur selben Minute abgefragt.

```bash
sudo install -m 0755 update-trial-token.py /usr/local/bin/update-trial-token.py
sudo systemctl daemon-reload
sudo systemctl enable --now evcc-trial-token.timer
systemctl list-timers evcc-trial-token.timer
journalctl -u evcc-trial-token.service
```

## Wiederherstellung von Hand

Das Backup liegt neben der Konfiguration und enthält immer den Stand *vor* dem
letzten Schreibversuch:

```bash
sudo cp /etc/evcc.yaml.trial-updater.bak /etc/evcc.yaml
sudo systemctl restart evcc
```

## Tests

```bash
bash tests/test-evcc.sh                      # ohne Netzwerk, ohne systemd
EVCC_LIVE_TEST=1 bash tests/test-evcc.sh     # zusätzlich gegen docs.evcc.io
```

43 Prüfungen ohne Netzwerk, mit `EVCC_LIVE_TEST=1` eine zusätzliche; die Suite
nennt die Zahl am Ende selbst. `systemctl` und alle HTTP-Zugriffe sind durch
Attrappen ersetzt, gearbeitet wird in einem temporären Verzeichnis – das System
wird nicht verändert. Abgedeckt sind die JWT-Auswertung, alle
YAML-Zeilenvarianten (Anführungszeichen, Kommentar, CRLF, eingerückt, doppelt),
der Formaterhalt beim Tausch, Datei- und Backup-Rechte, das Rollback nach
fehlgeschlagenem Neustart, sämtliche Ablehnungspfade und die tokenfreie
Logausgabe.

`EVCC_LIVE_TEST=1` fragt zusätzlich die echte evcc-Dokumentation ab und schlägt
fehl, wenn dort kein gültiges Testtoken mehr zu finden ist – nützlich, um eine
Änderung am Seitenaufbau zu bemerken. In der CI läuft diese Prüfung bewusst
nicht mit, damit die Pipeline nicht von der Verfügbarkeit der Seite abhängt.
