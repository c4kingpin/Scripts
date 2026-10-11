# evcc – Testtoken-Aktualisierung (Raspberry Pi)

[`update-trial-token.py`](update-trial-token.py) ersetzt das offizielle
evcc-**Testtoken** durch das aktuelle Token aus der
[evcc-Dokumentation](https://docs.evcc.io/de/sponsorship/) und startet den
Dienst neu. Reine Python-Standardbibliothek – keine zusätzlichen Pakete.

Es werden **beide Konfigurationswege** von evcc unterstützt und im Modus
`auto` selbst erkannt:

| Weg | Wo das Token liegt | Wie das Skript es ändert |
| --- | --- | --- |
| YAML-Datei (traditionell) | `sponsortoken:` in `/etc/evcc.yaml` | formaterhaltender Zeilentausch, atomar, mit Backup |
| Weboberfläche (empfohlen, Standard) | `sponsorToken` in der evcc-Datenbank, i. d. R. `/var/lib/evcc/evcc.db` | über die offizielle CLI `evcc settings get/set` |

Wichtig für den zweiten Fall: Das `.deb`-Paket legt **keine** `/etc/evcc.yaml`
an. Wer evcc über die Weboberfläche konfiguriert hat, hat gar keine
YAML-Datei — dort greift der Datenbankmodus.

Hintergrund: Das Testtoken ist absichtlich kurzlebig und wird von evcc in
unregelmäßigen Abständen erneuert. Läuft es ab, fallen die Sponsor-Funktionen
aus, bis das Token von Hand ersetzt wird. Genau diesen Handgriff automatisiert
das Skript – und zwar so, dass es im Zweifelsfall lieber nichts tut.

> **Status:** Die Regressionstests laufen durch, die Tokenquelle ist live gegen
> `docs.evcc.io` geprüft, und der Datenbankmodus ist gegen eine echte
> evcc-Binary (0.317.1) getestet — Lesen, Schreiben, Zurückschreiben. Was noch
> fehlt, ist ein Durchlauf auf echter Hardware mit laufendem Dienst und
> echtem systemd; `systemctl` ist in allen Tests eine Attrappe. Zuerst
> `--dry-run` verwenden.

## Voraussetzungen

- evcc per `apt`/`.deb` installiert und als systemd-Dienst `evcc` aktiv
- Ein bereits vorhandenes **Testtoken** – entweder als `sponsortoken:` auf
  oberster Ebene einer YAML-Datei, oder als `sponsorToken` in der
  evcc-Datenbank (zur unterschiedlichen Schreibweise siehe unten)
- Für den Datenbankmodus: die `evcc`-CLI im `PATH` (beim `.deb`-Paket gegeben)
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
- **Direkt in der SQLite-Datei schreiben.** Im Datenbankmodus läuft jeder
  Zugriff über `evcc settings get/set`. Schema und Ablage der Datenbank sind
  kein zugesichertes Format, die CLI ist die dokumentierte Schnittstelle.
- **Ein Token anlegen, wo keines ist.** Ist weder in der YAML-Datei noch in der
  Datenbank ein Token gesetzt, bricht das Skript ab. Es ersetzt nur, es richtet
  nicht ein. Das erste Token trägst du in der Weboberfläche unter Sponsoring
  ein (oder in die YAML-Datei).
- **Die JWT-Signatur prüfen.** Es gibt keinen öffentlichen Signaturschlüssel.
  Das Vertrauen stützt sich auf TLS zu `docs.evcc.io` – siehe
  [Sicherheitszusagen](#sicherheitszusagen).

## Installation

Das Skript installiert evcc **nicht**. Es setzt eine laufende Installation
voraus und tauscht dort nur das Testtoken.

### 1. Vorprüfung

Das Skript bricht bei jeder nicht erfüllten Voraussetzung ab, statt etwas falsch
zu machen. Vorher zu wissen, woran es liegt, spart trotzdem Zeit:

```bash
systemctl is-active evcc                      # muss "active" sein
python3 --version
# 0 Treffer oder Datei fehlt => Datenbankmodus
sudo grep -c '^sponsortoken:' /etc/evcc.yaml
curl -s http://127.0.0.1:7070/api/state | head -c 120
```

Ein `401` in der letzten Zeile heißt: `--api-key-file` wird gebraucht. Fehlt
`/etc/evcc.yaml`, ist das der Normalfall bei Konfiguration über die
Weboberfläche — dann greift der Datenbankmodus, ohne dass du etwas angeben
musst.

### 2. Skript holen und ansehen

```bash
curl -fsSL -o /tmp/update-trial-token.py \
  https://raw.githubusercontent.com/c4kingpin/Scripts/master/evcc/update-trial-token.py
less /tmp/update-trial-token.py
chmod +x /tmp/update-trial-token.py
```

Der zweite Schritt ist kein Ritual: Das Skript schreibt nach `/etc` bzw. in die
evcc-Datenbank und startet einen Dienst neu. Wer es ausführt, sollte es gelesen
haben. Eine Prüfsumme steht hier bewusst nicht — sie würde bei jeder Änderung
des Skripts veralten und wäre dann irreführend. Wer den Inhalt gegen das
Repository abgleichen will, klont es und vergleicht mit `git diff`.

### 3. Trockenlauf

Der wichtigste Schritt. Schreibt nichts und startet nichts neu:

```bash
sudo /tmp/update-trial-token.py --dry-run
```

Die erste Zeile nennt die erkannte Konfigurationsquelle. Erwartet sind danach
zwei Datumszeilen und entweder `Keine Aenderung erforderlich.` oder
`TROCKENLAUF: Neueres Token gefunden.` Alles andere steht mit seiner Bedeutung
unter [Typische Meldungen](#typische-meldungen).

### 4. Echter Lauf

```bash
sudo /tmp/update-trial-token.py
```

Startet evcc neu. Das Skript verschiebt die Aktualisierung von selbst, wenn
gerade geladen wird; eine ruhige Zeit zu wählen ist trotzdem sinnvoll.

### 5. Dauerhaft einrichten

Erst wenn Schritt 4 sauber lief:

```bash
sudo install -m 0755 /tmp/update-trial-token.py \
  /usr/local/bin/update-trial-token.py
```

Danach die Unit-Dateien aus
[Regelmäßig ausführen](#regelmäßig-ausführen-systemd-timer) anlegen.

## Verwendung

```bash
sudo ./update-trial-token.py --dry-run        # nur prüfen
sudo ./update-trial-token.py                  # tatsächlich aktualisieren
```

| Option | Standard | Zweck |
| --- | --- | --- |
| `--mode` | `auto` | `auto`, `yaml` oder `db` – erzwingt einen Konfigurationsweg |
| `--config` | `/etc/evcc.yaml` | Pfad zur YAML-Konfiguration |
| `--database` | aus der systemd-Unit, sonst `/var/lib/evcc/evcc.db` | Pfad zur evcc-Datenbank |
| `--evcc-bin` | `evcc` aus dem `PATH` | Pfad zur evcc-CLI |
| `--service-user` | `evcc` | Nutzer für den Datenbankzugriff; leer = nicht wechseln |
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
| `Konfigurationsquelle: …` | Erste Zeile jedes Laufs; zeigt, welcher Weg erkannt wurde. |
| `In der evcc-Datenbank ist kein 'sponsorToken' gesetzt.` | Es gibt kein Testtoken zum Ersetzen – erst eines in der Weboberfläche unter Sponsoring eintragen. |
| `Die Datenbank enthaelt 'sponsortoken', aber kein 'sponsorToken'.` | Ein Eintrag mit falscher Schreibweise, den evcc nie liest. Entfernen und das Token in der Weboberfläche eintragen. |
| `Keine evcc-Datenbank unter …` | Falscher Pfad; mit `--database` angeben. |
| `Kein YAML-Eintrag 'sponsortoken:' …` | Nur im Modus `yaml`: der Eintrag fehlt oder ist eingerückt. |
| `Auf der offiziellen evcc-Seite wurde kein noch gueltiges Testtoken gefunden.` | Entweder ist das Doku-Token abgelaufen, oder der Seitenaufbau hat sich geändert. |
| `evcc wurde nach Neustart nicht aktiv.` | Die Originaldatei wurde zurückgerollt – `journalctl -u evcc` prüfen. |

## Datenbankmodus im Detail

Alles hier Beschriebene ist gegen die echte evcc-Binary 0.317.1 gemessen, nicht
aus der Doku abgeleitet:

- **Der Schlüssel heißt `sponsorToken`, mit grossem T.** evcc vergleicht
  Einstellungsschlüssel exakt (`db/settings/setting.go`: `s.Key == key`, keine
  Normalisierung) und liest ausschließlich diese Schreibweise
  (`core/keys/global.go`). Ein Eintrag namens `sponsortoken` steht als zweiter,
  eigener Datensatz daneben und wird **nie gelesen** – gemessen: mit
  `sponsorToken` meldet die API `name: trial` samt Ablaufdatum, mit
  `sponsortoken` bleibt der Sponsor-Status leer. In der **YAML-Datei** heißt
  derselbe Wert dagegen `sponsortoken` (klein), weil die YAML-Ebene Schlüssel
  normalisiert. Diese Asymmetrie ist die unangenehmste Falle des
  Datenbankmodus; das Skript erkennt einen Eintrag mit abweichender
  Schreibweise und benennt ihn, statt ihn zu übergehen.
- **Zugriff als Dienstnutzer, nicht als root.** Die Datenbank läuft im
  SQLite-WAL-Modus und legt beim Zugriff `-wal`/`-shm`-Seitendateien an, die dem
  *schreibenden* Nutzer gehören. Ein Schreibzugriff als root kann also Dateien
  hinterlassen, die der als `evcc` laufende Dienst danach nicht mehr beschreiben
  kann. Das Skript wechselt deshalb per `runuser` (Rückfall: `sudo -n -u`) auf
  `--service-user`, sobald es selbst root ist.
- **Der Datenbankpfad kommt aus der systemd-Unit.** Das `.deb`-Paket setzt
  `Environment=EVCC_DATABASE_DSN=/var/lib/evcc/evcc.db`; das Skript liest das
  per `systemctl show` aus, statt sich auf den CLI-Standard `~/.evcc/evcc.db` zu
  verlassen. Dieser Standard wäre unter `sudo` das Home von **root** – das
  Skript würde dann an der falschen Datenbank arbeiten und nichts bewirken.
- **Ein Neustart ist nötig.** Wird das Token bei laufendem Dienst geändert,
  übernimmt evcc es nicht; der Sponsor-Status blieb in der Messung über 30
  Sekunden unverändert – nachgemessen mit dem korrekten Schlüssel. Deshalb
  startet das Skript den Dienst neu, mit denselben Vorsichtsmaßnahmen wie im
  YAML-Modus.
- **`evcc settings set` braucht `-f`.** Ohne das Flag fragt die CLI interaktiv
  nach und bricht ohne Terminal mit `FATAL` ab. In einem Timer wäre das ein
  Hänger, deshalb wird `-f` immer mitgegeben.
- **Die CLI mischt Logzeilen in ihre Nutzausgabe.** `evcc settings get` schreibt
  seine `INFO`-Zeilen auf *stdout*, direkt zwischen die `key: value`-Paare, und
  `-l error` unterdrückt sie nicht vollständig. Das Skript filtert deshalb
  zeilenweise, statt die Ausgabe einfach zu lesen.

Eine Einschränkung, die bleibt: Beim Schreiben steht das neue Token als
Kommandozeilenargument kurz in der Prozessliste und ist damit über `/proc` für
andere lokale Nutzer sichtbar. Die evcc-CLI nimmt den Wert nur als Argument, ein
anderer Weg existiert nicht. Betroffen ist ausschließlich das **öffentliche**
Testtoken aus der Dokumentation – ein Sponsor-Token wird nie geschrieben.

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
- Im Datenbankmodus wird der Vorgängerwert gemerkt und bei einem Fehler
  zurückgeschrieben. Der Anker dafür wird nur beim ersten Lesen gesetzt und
  kann durch ein erneutes Lesen nicht verlorengehen.
- Scheitert der Neustart, wird der vorherige Stand wiederhergestellt – die
  Originaldatei im YAML-Modus, der alte Wert im Datenbankmodus.
- Wurde die Datei zwischen Lesen und Schreiben von anderer Seite verändert,
  bricht das Skript ab, statt die fremde Änderung zu überschreiben.
- Symlinks als Konfigurationspfad werden abgelehnt; mehrere oder eingerückte
  `sponsortoken`-Einträge führen zum Abbruch statt zu einer falschen Änderung.
- Kommentar, Anführungszeichen und Zeilenenden der Zeile bleiben unverändert.
- Es landet nie ein JWT in der Logausgabe – auch nicht in Fehlermeldungen und
  nicht in durchgereichten Ausgaben von `systemctl` oder der evcc-CLI, die vor
  der Ausgabe von JWTs befreit werden.
- Im Modus `auto` führt eine vorhandene, aber abgelehnte YAML-Datei (Symlink,
  kein UTF-8, nicht lesbar) zum Abbruch und **nicht** still zum
  Datenbankmodus.

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

Im **YAML-Modus** liegt das Backup neben der Konfiguration und enthält den Stand
*vor* dem letzten Schreibversuch:

```bash
sudo cp /etc/evcc.yaml.trial-updater.bak /etc/evcc.yaml
sudo systemctl restart evcc
```

Im **Datenbankmodus** gibt es keine Backup-Datei; das Skript schreibt bei einem
Fehler selbst zurück. Von Hand geht es über die Weboberfläche oder die CLI:

```bash
sudo runuser -u evcc -- evcc settings set --database /var/lib/evcc/evcc.db \
  -f sponsortoken '<token>'
sudo systemctl restart evcc
```

## Tests

```bash
# ohne Netzwerk, ohne systemd, ohne evcc
bash tests/test-evcc.sh

# zusätzlich gegen docs.evcc.io
EVCC_LIVE_TEST=1 bash tests/test-evcc.sh
```

74 Prüfungen ohne Netzwerk und ohne evcc; die Suite nennt die Zahl am Ende
selbst. Zwei optionale Erweiterungen:

| Variable | Wirkung |
| --- | --- |
| `EVCC_LIVE_TEST=1` | fragt zusätzlich die echte evcc-Dokumentation ab |
| `EVCC_REAL_BIN=/pfad/zu/evcc` | testet den Datenbankmodus gegen eine echte evcc-Binary statt gegen die Stub-CLI (6 weitere Prüfungen) |

```bash
EVCC_REAL_BIN=/usr/bin/evcc bash tests/test-evcc.sh
```
 `systemctl` und alle HTTP-Zugriffe sind durch
Attrappen ersetzt, gearbeitet wird in einem temporären Verzeichnis – das System
wird nicht verändert. Abgedeckt sind die JWT-Auswertung, alle
YAML-Zeilenvarianten (Anführungszeichen, Kommentar, CRLF, eingerückt, doppelt),
der Formaterhalt beim Tausch, Datei- und Backup-Rechte, das Rollback nach
fehlgeschlagenem Neustart, sämtliche Ablehnungspfade und die tokenfreie
Logausgabe. Für den Datenbankmodus kommt eine Stub-CLI zum Einsatz, die die
gemessenen Eigenheiten des Originals nachbildet — Logzeilen auf stdout,
Pflicht-`-f`, Exitcode 1 — damit der echte Filter- und Parsercode geprüft wird.

`EVCC_LIVE_TEST=1` fragt zusätzlich die echte evcc-Dokumentation ab und schlägt
fehl, wenn dort kein gültiges Testtoken mehr zu finden ist – nützlich, um eine
Änderung am Seitenaufbau zu bemerken. In der CI läuft diese Prüfung bewusst
nicht mit, damit die Pipeline nicht von der Verfügbarkeit der Seite abhängt.
