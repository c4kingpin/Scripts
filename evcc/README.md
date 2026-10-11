# evcc – Testtoken-Aktualisierung (Raspberry Pi)

`update-trial-token.py` ersetzt das offizielle evcc-**Testtoken** in
`/etc/evcc.yaml` durch das aktuelle Token aus der
[evcc-Dokumentation](https://docs.evcc.io/de/sponsorship/) und startet den
Dienst neu. Reines Python 3 der Standardbibliothek – keine zusätzlichen Pakete.

> **Status:** Automatisierte Tests laufen durch, die Tokenquelle ist live gegen
> `docs.evcc.io` geprüft. Ein Durchlauf auf echter Hardware mit laufendem
> evcc-Dienst steht noch aus – zuerst `--dry-run` verwenden.

## Voraussetzungen

- evcc per `apt`/`.deb` installiert und als systemd-Dienst `evcc` aktiv
- Konfiguration in einer **YAML-Datei** mit `sponsortoken:` auf oberster Ebene
  (bei Konfiguration über die Weboberfläche liegt das Token in der Datenbank –
  dann bricht das Skript bewusst ab)
- Python 3.9 oder neuer

## Verwendung

```bash
sudo ./update-trial-token.py --dry-run        # nur prüfen
sudo ./update-trial-token.py                  # tatsächlich aktualisieren
```

Optionen:

| Option | Standard | Zweck |
| --- | --- | --- |
| `--config` | `/etc/evcc.yaml` | Pfad zur YAML-Konfiguration |
| `--state-url` | `http://127.0.0.1:7070/api/state` | lokale evcc-API; nur `127.0.0.1`, `localhost`, `::1` erlaubt |
| `--api-key-file` | – | Datei mit einem `evcc_…`-API-Key, falls die API geschützt ist |
| `--dry-run` | – | prüfen, ohne zu schreiben oder neu zu starten |

Rückgabewert `0` bei Erfolg oder wenn keine Änderung nötig war, `1` bei Fehlern.

## Sicherheitszusagen

Jeder Punkt ist durch einen Test in `tests/` abgedeckt:

- Tokenquelle ausschließlich `https://docs.evcc.io` – eine HTTP-Weiterleitung
  auf einen fremden Host bricht ab.
- Akzeptiert nur JWTs mit `iss=evcc.io` **und** `sub=trial`, nur unverfallen.
- **Sponsor- und Contributor-Tokens werden nie ersetzt** – ebenso kein Token,
  dessen Ablaufdatum nicht später liegt als das bestehende.
- Kein Schreiben und kein Neustart, solange die evcc-API einen aktiven
  Ladevorgang meldet (geprüft vor dem Schreiben **und** direkt vor dem Neustart).
- Backup nach `/etc/evcc.yaml.trial-updater.bak` mit Rechten `0600`; der Tausch
  erfolgt atomar (`fsync` + `os.replace`), Eigentümer und Rechte bleiben erhalten.
- Scheitert der Neustart, wird die Originaldatei wiederhergestellt.
- Symlinks als Konfigurationspfad werden abgelehnt; mehrere oder eingerückte
  `sponsortoken`-Einträge führen zum Abbruch statt zu einer falschen Änderung.
- Kommentar, Anführungszeichen und Zeilenenden der Zeile bleiben unverändert.
- Es landet nie ein JWT in der Logausgabe.

Die JWT-Signatur wird **nicht** lokal geprüft – es gibt keinen öffentlichen
Signaturschlüssel. Das Vertrauen stützt sich auf TLS zu `docs.evcc.io`.

## Regelmäßig ausführen (systemd-Timer)

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

```bash
sudo install -m 0755 update-trial-token.py /usr/local/bin/update-trial-token.py
sudo systemctl daemon-reload
sudo systemctl enable --now evcc-trial-token.timer
journalctl -u evcc-trial-token.service
```

## Tests

```bash
bash evcc/tests/test-evcc.sh                      # ohne Netzwerk, ohne systemd
EVCC_LIVE_TEST=1 bash evcc/tests/test-evcc.sh     # zusätzlich gegen docs.evcc.io
```

Die Tests ersetzen `systemctl` und alle HTTP-Zugriffe durch Attrappen und
arbeiten in einem temporären Verzeichnis; das System wird nicht verändert.
