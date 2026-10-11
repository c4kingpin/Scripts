# Scripts

Sammlung eigenständiger Installations- und Verwaltungsskripte. Jedes Projekt
liegt in einem eigenen Unterverzeichnis mit eigener Dokumentation und eigenen
Tests.

| Projekt | Beschreibung |
| --- | --- |
| [`devbox/`](devbox/) | Isolierte Entwicklungsumgebung für Codex und Claude in einem Ubuntu-LXC-Container: Agenten-CLIs, Node.js, Erlang/Elixir/Phoenix, PostgreSQL, GitHub CLI. |
| [`evcc/`](evcc/) | Wartung einer evcc-Installation (Ladesteuerung für E-Autos) auf einem Raspberry Pi: tauscht das ablaufende Testtoken in `/etc/evcc.yaml`. |
| [`theater/`](theater/) | Ubuntu-24.04-Grundinstallation für Linux Show Player, Focusrite Scarlett 18i20 (1st Gen) und MIDI-Ansteuerung eines MA Lightcommander. |

## Aufbau

```text
<projekt>/
  README.md       – Dokumentation des Projekts
  tests/          – Regressionstests, Einstiegspunkt tests/test-<projekt>.sh
  <skript>        – das Projektskript selbst
```

Das Projektskript heißt `install.sh`, wenn es ein direkt per `curl`
ausführbarer Installer ist (so bei [`devbox/`](devbox/) und
[`theater/`](theater/)); sonst trägt es einen sprechenden Namen und darf auch
in einer anderen Sprache geschrieben sein (so
[`evcc/update-trial-token.py`](evcc/update-trial-token.py)). Die Sprache ist
eine Projektentscheidung — Bedingung ist nur, dass das Skript ohne zusätzlich
zu installierende Pakete läuft.

## Tests

Die CI prüft bei jedem Push und Pull Request **alle** `*.sh`-Dateien im
Repository mit `bash -n` und ShellCheck und führt die Testdateien aus, die in
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) eingetragen sind.
Vollständig lokal:

```bash
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n

find . -name '*.sh' -not -path './.git/*' -print0 |
  xargs -0 shellcheck -x --exclude=SC1090,SC1091

bash devbox/tests/test-devbox.sh
bash evcc/tests/test-evcc.sh
bash theater/tests/test-theater.sh
```

Die Regressionstests laufen ohne Netzwerkzugriff und ohne das System zu
verändern; Dienste und HTTP-Abfragen werden durch Attrappen ersetzt. Einzelne
Projekte kennen zusätzlich optionale Prüfungen gegen echte externe Quellen, die
in der CI bewusst nicht mitlaufen — bei evcc etwa `EVCC_LIVE_TEST=1`.

`bash -n` und ShellCheck erfassen ein neues Projekt automatisch, sobald es
`*.sh`-Dateien enthält. Seine Regressionstests laufen dagegen **nur**, wenn
die Testdatei von Hand in `ci.yml` eingetragen wird — ohne diesen Eintrag
existiert die Suite, wird aber nie ausgeführt. Ist das Projekt nicht in Bash
geschrieben, gehört zusätzlich eine passende Syntaxprüfung in seine eigene
Testdatei (bei evcc übernimmt `tests/test-evcc.sh` das per
`python3 -m py_compile`).
