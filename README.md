# Codex DevBox für Proxmox

Dieses Repository enthält einen Community-Scripts-kompatiblen LXC-Installer
für eine isolierte Codex-Entwicklungsumgebung. Die Struktur entspricht dem
aktuellen Entwicklungsrepository
[ProxmoxVED](https://github.com/community-scripts/ProxmoxVED):

- `ct/codex-devbox.sh` – Proxmox-Dialog, Container-Erstellung und Updates
- `install/codex-devbox-install.sh` – Installation innerhalb des Containers
- `json/codex-devbox.json` – Community-Scripts-Metadaten

Der frühere eigenständige Proxmox-Monolith wurde durch die zentralen
Community-Scripts-Funktionen ersetzt. Storage-, Netzwerk-, Template-,
Ressourcen- und Container-Dialoge kommen dadurch direkt aus dem Upstream-
Framework.

## Standardkonfiguration

| Einstellung | Standard |
| --- | --- |
| Betriebssystem | Debian 13 |
| Container | unprivilegiert |
| CPU | 4 Kerne |
| RAM | 8192 MiB |
| Speicher | 32 GiB |
| Architektur | amd64 |
| Benutzer | `dev` |
| Workspace | `/home/dev/workspace` |
| Codex-Autonomie | ausgewogen |

Installiert werden unter anderem Codex CLI, Node.js 24, Git, Git LFS, GitHub
CLI, Python, ShellCheck, ripgrep, `fd`, Erlang/OTP, Elixir, Phoenix und
PostgreSQL. Erlang, Elixir und Phoenix werden für den Benutzer `dev` über
`mise` verwaltet.

## Installation

Das Skript wird in der Proxmox-VE-Shell als `root` gestartet.

Solange die Dateien in diesem eigenständigen Repository liegen:

```bash
CODEX_DEVBOX_SOURCE_URL="https://raw.githubusercontent.com/c4kingpin/Scripts/master" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/ct/codex-devbox.sh)"
```

`CODEX_DEVBOX_SOURCE_URL` sorgt dafür, dass das offizielle Community-Framework
den zugehörigen Installer aus diesem Repository lädt. Nach einer Aufnahme in
`community-scripts/ProxmoxVED` genügt der normale Community-Aufruf:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/ct/codex-devbox.sh)"
```

Das Community-Scripts-Framework bietet die Standard- und erweiterten
Installationsdialoge. Darin können unter anderem VMID, Hostname, Storage,
Bridge, IP-Konfiguration, DNS und ein vorhandener SSH-Public-Key festgelegt
werden.

Vor dem Erstellen des Containers fragt das Skript zusätzlich, wie autonom Codex
arbeiten darf:

| Profil | Codex-Verhalten |
| --- | --- |
| Kontrolliert | Nur lesender Zugriff; Änderungen und Befehle benötigen eine Freigabe. |
| Ausgewogen (Standard) | Codex darf den Workspace selbstständig bearbeiten und fragt für Zugriffe außerhalb des Workspace oder auf das Netzwerk. |
| Autonom | Codex darf den Workspace bearbeiten und das Netzwerk ohne Freigabedialoge nutzen; die Workspace-Sandbox bleibt aktiv. |
| Vollzugriff | Keine Sandbox und keine Freigabedialoge innerhalb des LXC-Containers. |

Die Auswahl wird als `approval_policy` und `sandbox_mode` in
`/home/dev/.codex/config.toml` gespeichert und kann dort später geändert werden.
Bei einer unbeaufsichtigten Installation wird `balanced` verwendet. Alternativ
kann das Profil vorgegeben werden:

```bash
var_codex_autonomy=autonomous \
  CODEX_DEVBOX_SOURCE_URL="https://raw.githubusercontent.com/c4kingpin/Scripts/master" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/ct/codex-devbox.sh)"
```

Gültige Werte sind `controlled`, `balanced`, `autonomous` und `full-access`.
`full-access` hebt nur die innere Codex-Sandbox auf; die Grenze des
unprivilegierten LXC-Containers bleibt bestehen.

## Erster Login und Onboarding

Die Devbox ist immer über die Proxmox-Konsole nutzbar; SSH ist keine
Voraussetzung:

```bash
pct enter <CTID>
sudo -iu dev
```

Beim ersten interaktiven Login startet das optionale Onboarding. Es kann
jederzeit wiederholt werden:

```bash
codex-devbox onboard
```

Das Onboarding behandelt nacheinander:

1. optionalen eingehenden SSH-Zugang,
2. optionale Codex-CLI-Anmeldung per Gerätecode,
3. optionalen OpenRouter-API-Key samt Modell für Codex,
4. GitHub-Anmeldung und Git-Identität,
5. einen optionalen ausgehenden Ed25519-Schlüssel der Devbox,
6. Diagnose und Hinweise zur ChatGPT-Mobilverbindung.

Der Abschluss wird in
`~/.config/codex-devbox/onboarding-complete` vermerkt. Das Onboarding kann
trotzdem jederzeit erneut aufgerufen werden.

## SSH sicher einrichten

SSH bleibt deaktiviert, solange kein Public Key hinterlegt ist. Wurde im
erweiterten Proxmox-Dialog bereits ein SSH-Key angegeben, übernimmt der
Installer diesen für `dev` und aktiviert den Dienst.

Andernfalls wird der Zugriff später eingerichtet. Der private Schlüssel wird
auf dem Mac, Windows-PC oder sonstigen SSH-Client erzeugt, der sich mit der
Devbox verbinden soll:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/codex-devbox
```

Nur die einzelne Zeile aus `~/.ssh/codex-devbox.pub` wird im Onboarding
eingefügt. Der private Client-Schlüssel gehört nicht auf die Devbox.

Verwaltung innerhalb des Containers:

```bash
codex-devbox ssh status
sudo /usr/local/bin/codex-devbox ssh setup
sudo /usr/local/bin/codex-devbox ssh disable
```

Die SSH-Konfiguration erlaubt ausschließlich Public-Key-Anmeldung für `dev`.
Root-, Passwort- und Keyboard-Interactive-Login sowie Agent-, TCP-, Socket-,
X11- und Tunnel-Forwarding sind deaktiviert.

## Devbox-Schlüssel und GitHub

Die Richtung der beiden Schlüsseltypen ist bewusst getrennt:

- Der Client-Schlüssel authentifiziert Mac oder Windows **an der Devbox**.
- Der optionale Devbox-Schlüssel authentifiziert die Devbox **an GitHub oder
  einem anderen Git-Server**.

GitHub wird standardmäßig per HTTPS über die GitHub CLI eingerichtet:

```bash
codex-devbox github setup
codex-devbox github status
```

Ein zusätzlicher ausgehender SSH-Schlüssel kann erzeugt und nach erfolgreicher
GitHub-Anmeldung hochgeladen werden:

```bash
codex-devbox keys generate
codex-devbox keys status
codex-devbox keys upload-github
```

Private Schlüssel, GitHub-Tokens und Codex-Anmeldedaten werden weder vom
Installer ausgegeben noch in dieses Repository geschrieben.

## Codex-Anmeldung

Die Codex-Anmeldung findet erst im Benutzerterminal statt, niemals während der
Installation. Für die headless Devbox verwendet der Manager den Gerätecode-
Flow:

```bash
codex-devbox auth login
codex-devbox auth status
codex-devbox auth logout
```

Codex verwaltet seine Anmeldung selbst unter `~/.codex`. Dieser Ordner darf
nicht kopiert, veröffentlicht oder eingecheckt werden. Die CLI-Anmeldung ist
von der Einrichtung einer ChatGPT-Remote-Verbindung in der Desktop-App
getrennt.

## OpenRouter für Codex

Alternativ zur Codex-CLI-Anmeldung kann ein OpenRouter-API-Key hinterlegt
werden:

```bash
codex-devbox openrouter setup
codex-devbox openrouter status
```

Die Einrichtung fragt den Key verdeckt und ein OpenRouter-Modell ab. Ohne
Modellangabe wird `~openai/gpt-latest` verwendet. Der Key liegt ausschließlich
in `~/.config/codex-devbox/openrouter.env` mit Dateimodus `0600`; Statusausgaben
zeigen seinen Wert nie an. Codex wird über das Profil
`~/.codex/openrouter.config.toml` mit dem OpenRouter-Endpunkt und der Responses
API gestartet.

Die OpenRouter-Einrichtung lässt sich einschließlich des gespeicherten Keys
wieder entfernen:

```bash
codex-devbox openrouter disable
```

Danach nutzt `codex` wieder seine normale Konfiguration und gegebenenfalls die
separate Codex-CLI-Anmeldung.

## ChatGPT auf iPhone oder iPad

Die unterstützte Verbindung läuft über einen gekoppelten Desktop-Rechner:

```text
ChatGPT auf iOS
  → ChatGPT Desktop auf macOS oder Windows
  → SSH-Verbindung zur Devbox
  → Projekt unter /home/dev/workspace
```

Die Remote-Verbindung wird in der ChatGPT-Desktop-App unter den SSH-
Verbindungen eingerichtet. Sie kann nicht über einen `codex remote-control`
CLI-Dienst auf der Linux-Devbox gestartet werden. Danach kann die gekoppelte
iOS-App auf die vom Desktop bereitgestellte Remote-Umgebung zugreifen.

Die aktuellen Hinweise zeigt auch:

```bash
codex-devbox remote-info
```

Ohne SSH bleibt die Devbox vollständig über `pct enter` und `sudo -iu dev`
nutzbar.

## PostgreSQL

Der Installer legt die lokale Entwicklungsdatenbank `devbox` und die Rolle
`dev` mit einem zufälligen Passwort an. Die Zugangsdaten liegen ausschließlich
im Container:

```text
/home/dev/.pgpass
/home/dev/.config/codex-devbox/postgres.env
```

Beide Dateien gehören `dev` und haben Modus `0600`. Für ein Phoenix-Projekt
kann die Umgebung beispielsweise so geladen werden:

```bash
set -a
source ~/.config/codex-devbox/postgres.env
set +a
```

## Betrieb und Updates

Diagnose:

```bash
codex-devbox doctor
```

Der offizielle Updatepfad wird über `update_script()` im CT-Wrapper
bereitgestellt. Auf dem Proxmox-Host kann derselbe Installationsaufruf erneut
gestartet und der vorhandene Container zum Update ausgewählt werden. Innerhalb
des Containers steht zusätzlich der Manager zur Verfügung:

```bash
sudo codex-devbox update
```

Das Update aktualisiert Debian-Pakete, Codex CLI und die verwaltete
Erlang-/Elixir-/Phoenix-Toolchain. Workspace, SSH-Schlüssel, Codex-
Anmeldedaten, Git-Konfiguration und PostgreSQL-Daten werden nicht gelöscht.

Automatische Sicherheitsupdates sind aktiviert. Da `dev` bewusst kein
allgemeines passwortloses `sudo` besitzt, erfolgen Systemänderungen entweder
über den eingeschränkten SSH-Onboarding-Befehl oder über die Proxmox-
Root-Konsole.

## Tests

Lokale Prüfungen:

```bash
bash -n \
  ct/codex-devbox.sh \
  install/codex-devbox-install.sh \
  tests/test-codex-devbox.sh

python3 -m json.tool json/codex-devbox.json >/dev/null
bash tests/test-codex-devbox.sh

shellcheck -x \
  ct/codex-devbox.sh \
  install/codex-devbox-install.sh \
  tests/test-codex-devbox.sh
```

Diese Prüfungen laufen bei Pushes und Pull Requests über GitHub Actions. Ein
vollständiger End-to-End-Test erfordert weiterhin einen Proxmox-VE-Testhost,
weil Container-, Storage- und Netzwerkoperationen lokal nicht realistisch
simuliert werden können.

## Upstream-Dokumentation

- [Community-Scripts: CT detailed guide](https://community-scripts.org/docs/ct/detailed_guide)
- [Community-Scripts: Install detailed guide](https://community-scripts.org/docs/install/detailed_guide)
- [Community-Scripts: Contribution workflow](https://github.com/community-scripts/ProxmoxVE/blob/main/CONTRIBUTING.md)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [ChatGPT Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [Codex `AGENTS.md`](https://developers.openai.com/codex/guides/agents-md/)
- [mise](https://mise.jdx.dev/)
- [Phoenix installation](https://hexdocs.pm/phoenix/installation.html)
