# Scripts

Sammlung eigenständiger Installations- und Verwaltungsskripte. Jedes Projekt
liegt in einem eigenen Unterverzeichnis mit eigener Dokumentation und eigenen
Tests.

| Projekt | Beschreibung |
| --- | --- |
| [`devbox/`](devbox/) | Isolierte Entwicklungsumgebung für Codex und Claude in einem Ubuntu-LXC-Container: Agenten-CLIs, Node.js, Erlang/Elixir/Phoenix, PostgreSQL, GitHub CLI. |

## Aufbau

```text
<projekt>/
  install.sh      – der Installer, direkt per curl ausführbar
  README.md       – Dokumentation des Projekts
  tests/          – Regressionstests
```

## Tests

Die CI prüft bei jedem Push und Pull Request **alle** `*.sh`-Dateien im
Repository mit `bash -n` und ShellCheck und führt die Regressionstests aus.
Lokal:

```bash
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n

find . -name '*.sh' -not -path './.git/*' -print0 |
  xargs -0 shellcheck -x --exclude=SC1090,SC1091

bash devbox/tests/test-devbox.sh
```

Ein neues Projekt wird von den beiden Prüfschritten automatisch erfasst; nur
seine Testdatei muss im Workflow ergänzt werden.
