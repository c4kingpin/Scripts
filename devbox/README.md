# DevBox für LXC

[`install.sh`](install.sh) ist ein eigenständiger Installer für eine isolierte
Codex- und Claude-Entwicklungsumgebung. Das Skript läuft direkt **innerhalb**
eines bereits vorhandenen, unprivilegierten LXC-Containers (Proxmox VE,
LXD/Incus oder jede andere Plattform), wird als `root` ausgeführt und richtet
dabei auch den `devbox`-Manager ein. Es hat keine Abhängigkeit zu Proxmox
selbst oder zu einem Framework.

Der `devbox`-Manager selbst liegt als eigenständige Quelldatei unter
[`bin/devbox.sh`](bin/devbox.sh) und wird von `install.sh` während der
Installation aus demselben Branch/Commit heruntergeladen und unverändert nach
`/usr/local/bin/devbox` geschrieben — so bleiben Installer und Manager immer
versionsgleich. Am dokumentierten Curl-Einzeiler ändert das nichts: `install.sh`
lädt ohnehin schon während der Installation weitere Artefakte (Pakete, Node.js,
Erlang/Elixir, Codex/Claude/Happy) nach.

Betriebslogik, die `install.sh` erst nach seiner Bootstrap-Phase (Root-/OS-/
Netzwerk-Check) braucht, wandert schrittweise in eigene, ebenfalls
nachgeladene Module unter [`lib/`](lib) (aktuell: [`lib/common.sh`](lib/common.sh)
mit der Checksum-Verifikation und dem `run_as_dev`-Helfer). Die Bootstrap-Kette
selbst bleibt bewusst in `install.sh`, da sie gebraucht wird, um diese Module
überhaupt herunterzuladen. `bin/devbox.sh` bleibt davon unabhängig eine
einzelne, in sich geschlossene Datei ohne Laufzeit-Abhängigkeit auf `lib/`,
damit `devbox`-Befehle nach der Installation ohne Netzwerkzugriff
funktionieren.

Das Skript erstellt oder konfiguriert den Container selbst nicht. Storage,
Netzwerk, Template und Ressourcen des Containers müssen vor dem Aufruf bereits
über das jeweilige Hypervisor-Tooling (`pct create`, `lxc launch`,
`incus launch`, …) vorhanden sein.

## Standardkonfiguration

| Einstellung | Standard |
| --- | --- |
| Benutzer | `dev` |
| Workspace | `/home/dev/workspace` |
| Agenten-Autonomie | ausgewogen |

Installiert werden unter anderem Codex CLI, Claude CLI, Node.js 24, Git, Git
LFS, GitHub CLI, Python, ShellCheck, ripgrep, `fd`, Erlang/OTP, Elixir,
Phoenix und PostgreSQL.

Erlang/OTP und Elixir werden **ohne Versionsmanager** systemweit unter
`/opt/devbox` installiert und über einfache Symlinks in `/usr/local/bin`
bereitgestellt:

| Komponente | Quelle | Ziel |
| --- | --- | --- |
| Erlang/OTP | vorkompilierter Build von builds.hex.pm (Architektur und Ubuntu-Version werden erkannt) | `/opt/devbox/otp` |
| Elixir | offizielles Release passend zur OTP-Hauptversion (`elixir-otp-27.zip`) | `/opt/devbox/elixir` |

Die OTP-Hauptversion für Elixir wird direkt aus der Erlang-Version abgeleitet,
sodass beide bei einem Versionswechsel nicht auseinanderlaufen können.

`mise` ist installiert und steht für andere Sprachen zur Verfügung (Go, Rust,
weitere Node-Versionen …), verwaltet aber bewusst **nicht** Erlang und Elixir:
Über seine Shims ausgeführt stürzte die BEAM beim Start der
`kernel`-Application ab. Frühere, von `mise` verwaltete BEAM-Installationen
werden beim Update entfernt; `mise` selbst bleibt erhalten.

Zusätzlich legt der Installer `~/.erlang.cookie` an, den Erlang beim Start der
`kernel`-Application schreibt.

### Erlang-Version

Voreingestellt ist **OTP 29.0.5**. OTP 28 stürzte in getesteten
LXC-Containern beim Start reproduzierbar ab — unabhängig von Distribution,
Installationsort, Benutzer und davon, ob vorkompiliert oder selbst gebaut.
Vermutlich setzt der JIT von OTP 28 CPU-Instruktionen voraus, die
konservative Hypervisor-CPU-Modelle nicht bereitstellen. OTP 29.0.5 läuft
auf denselben Containern reproduzierbar sauber durch. Der Installer prüft
die Runtime direkt nach der Installation und bricht mit klarer Meldung ab,
falls sie nicht läuft. Eine andere Version lässt sich vorgeben:

```bash
ERLANG_VERSION=28.4 bash install.sh
```

Empfohlene Containergröße: 4 CPU-Kerne, 8192 MiB RAM, 32 GiB Speicher,
unprivilegiert. Kleinere Container funktionieren ebenfalls.

### Betriebssystem: Ubuntu LTS erforderlich

Die DevBox setzt **Ubuntu 24.04 LTS** voraus (22.04 und 20.04 funktionieren
ebenfalls); amd64 und arm64 werden unterstützt. Der Installer prüft das zu
Beginn und bricht mit einer klaren Meldung ab, falls ein anderes System läuft.

Der Grund ist Erlang/OTP: builds.hex.pm veröffentlicht vorkompilierte
OTP-Builds ausschließlich für Ubuntu (für amd64 und arm64). Auf Debian gäbe es
kein passendes Archiv, und Erlang aus dem Quellcode zu übersetzen kostet viele
Minuten CPU-Zeit. Mit Ubuntu wird stattdessen ein fertiges Archiv entpackt.

## Installation

Zuerst einen unprivilegierten LXC-Container mit Ubuntu 24.04 LTS über das
jeweilige Hypervisor-Tooling anlegen und starten, zum Beispiel:

```bash
# Proxmox VE (Template ggf. zuvor mit "pveam download local <template>" holen)
pct create <CTID> local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname devbox --unprivileged 1 \
  --cores 4 --memory 8192 --rootfs local-lvm:32 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp
pct start <CTID>
```

```bash
# LXD / Incus
incus launch images:ubuntu/24.04 devbox \
  -c limits.cpu=4 -c limits.memory=8GiB
```

Danach das Skript als `root` **innerhalb** des Containers ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh | bash
```

Auf Proxmox VE zum Beispiel über die Konsole des Containers:

```bash
pct enter <CTID>
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh | bash
```

Auf LXD/Incus entsprechend über `lxc exec <name> -- bash` bzw.
`incus exec <name> -- bash`.

> **Hinweis zum Autonomie-Dialog:** Bei `curl | bash` ist die Standardeingabe
> mit der Pipe belegt, daher kann das Skript in diesem Fall **nicht**
> interaktiv nachfragen und verwendet automatisch `balanced`. Für den
> interaktiven Dialog das Skript zuerst herunterladen und dann als Datei
> ausführen:
>
> ```bash
> curl -fsSL -o install.sh \
>   https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh
> bash install.sh
> ```

Ausgeführt in einem echten Terminal fragt das Skript dann vor der eigentlichen
Installation, wie autonom die Agenten arbeiten dürfen. **Die Auswahl gilt für
Codex und Claude gemeinsam** — ein Profil, beide Agenten verhalten sich gleich:

| Profil | Verhalten | Codex | Claude |
| --- | --- | --- | --- |
| Kontrolliert | Nur lesender Zugriff; Änderungen und Befehle benötigen eine Freigabe. | `untrusted` / `read-only` | `default` |
| Ausgewogen (Standard) | Der Workspace darf selbstständig bearbeitet werden; Zugriffe nach außen werden erfragt. | `on-request` / `workspace-write` | `acceptEdits` |
| Autonom | Workspace und Netzwerk ohne Freigabedialoge; die Sandbox bleibt aktiv. | `never` / `workspace-write` | `auto` |
| Vollzugriff | Keine Sandbox und keine Freigabedialoge innerhalb des LXC-Containers. | `never` / `danger-full-access` | `bypassPermissions` |

Unabhängig vom Profil schützen `deny`-Regeln in `~/.claude/settings.json` die
Geheimnisse der Box (SSH-Schlüssel, `.pgpass`, Anmeldedaten, OpenRouter-Key) —
diese Regeln greifen in **jedem** Modus, auch bei `bypassPermissions`.

Ohne interaktives Terminal (also auch beim `curl | bash`-Einzeiler) wird
`balanced` verwendet, sofern nicht explizit ein Profil vorgegeben wird:

```bash
DEVBOX_AUTONOMY=autonomous \
  curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh | bash
```

Gültige Werte sind `controlled`, `balanced`, `autonomous` und `full-access`.
`full-access` hebt nur die innere Codex-Sandbox auf; die Grenze des
unprivilegierten LXC-Containers bleibt bestehen.

Gespeichert wird die Auswahl in `/home/dev/.codex/config.toml` (als
`approval_policy` und `sandbox_mode`) sowie in
`/home/dev/.claude/settings.json` (als `permissions.defaultMode`). Beide
Dateien können jederzeit von Hand angepasst werden; ein späterer
`devbox update` überschreibt sie nicht.

Dieselben Arbeitsregeln liegen für beide Agenten bereit — als
`~/.codex/AGENTS.md` für Codex und `~/.claude/CLAUDE.md` für Claude.

## Erster Login und Onboarding

Die Devbox ist immer über die Konsole des LXC-Hosts nutzbar; SSH ist keine
Voraussetzung:

```bash
pct enter <CTID>            # Proxmox VE
lxc exec <name> -- bash     # LXD
incus exec <name> -- bash   # Incus
sudo -iu dev
```

Beim ersten interaktiven Login startet das optionale Onboarding. Es kann
jederzeit wiederholt werden:

```bash
devbox onboard
```

Das Onboarding behandelt nacheinander:

1. optionalen eingehenden SSH-Zugang,
2. Anmeldung **beider** Agenten-CLIs, Codex und Claude,
3. optionalen OpenRouter-API-Key samt Modell als Codex-Fallback,
4. GitHub-Anmeldung und Git-Identität,
5. einen optionalen ausgehenden Ed25519-Schlüssel der Devbox,
6. Diagnose und Hinweise zur ChatGPT-Mobilverbindung.

Der Abschluss wird in
`~/.config/devbox/onboarding-complete` vermerkt. Das Onboarding kann
trotzdem jederzeit erneut aufgerufen werden.

## SSH sicher einrichten

SSH bleibt deaktiviert, solange kein Public Key hinterlegt ist. Ein Key kann
entweder vorab beim Installationsaufruf übergeben werden:

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... client" \
  curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh | bash
```

Andernfalls wird der Zugriff später eingerichtet. Der private Schlüssel wird
auf dem Mac, Windows-PC oder sonstigen SSH-Client erzeugt, der sich mit der
Devbox verbinden soll:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/devbox
```

Nur die einzelne Zeile aus `~/.ssh/devbox.pub` wird im Onboarding
eingefügt. Der private Client-Schlüssel gehört nicht auf die Devbox.

Verwaltung innerhalb des Containers:

```bash
devbox ssh status
sudo /usr/local/bin/devbox ssh setup
sudo /usr/local/bin/devbox ssh disable
```

Die SSH-Konfiguration erlaubt ausschließlich Public-Key-Anmeldung für `dev`.
Root-, Passwort- und Keyboard-Interactive-Login sowie Agent-, TCP-, Socket-,
X11- und Tunnel-Forwarding sind deaktiviert.

## Paketverwaltung

Der Benutzer `dev` besitzt **kein** allgemeines passwortloses `sudo apt`,
`apt-get` oder `dpkg`. OS-Pakete werden ausschließlich über den validierten
DevBox-Befehl installiert:

```bash
sudo devbox packages install imagemagick libvips
devbox packages list
```

Paketnamen werden gegen `^[a-z0-9][a-z0-9+.-]*$` geprüft; Optionen, Pfade,
Shell-Metazeichen oder Großschreibung werden abgelehnt. Agenten mit den
Autonomieprofilen `autonomous` oder `full-access` erhalten dadurch keinen
generischen Root-Zugriff auf die Paketverwaltung.

## Devbox-Schlüssel und GitHub

Die Richtung der beiden Schlüsseltypen ist bewusst getrennt:

- Der Client-Schlüssel authentifiziert Mac oder Windows **an der Devbox**.
- Der optionale Devbox-Schlüssel authentifiziert die Devbox **an GitHub oder
  einem anderen Git-Server**.

GitHub wird standardmäßig per HTTPS über die GitHub CLI eingerichtet:

```bash
devbox github setup
devbox github status
```

Ein zusätzlicher ausgehender SSH-Schlüssel kann erzeugt und nach erfolgreicher
GitHub-Anmeldung hochgeladen werden:

```bash
devbox keys generate
devbox keys status
devbox keys upload-github
```

Private Schlüssel, GitHub-Tokens und Codex-Anmeldedaten werden weder vom
Installer ausgegeben noch in dieses Repository geschrieben.

## Anmeldung der Agenten

Die Anmeldung findet erst im Benutzerterminal statt, niemals während der
Installation. Ein Befehl deckt **beide** Agenten ab und überspringt jeweils
den, der bereits angemeldet ist:

```bash
devbox auth login
devbox auth status
devbox auth logout
```

Beide CLIs sind für den headless Betrieb geeignet: Codex nutzt den
Gerätecode-Flow, Claude zeigt im Browser einen Anmeldecode, der im Terminal
eingefügt wird — der lokale Callback-Server ist aus einem Container ohnehin
nicht erreichbar.

Jede CLI verwaltet ihre Anmeldedaten selbst: Codex unter `~/.codex`, Claude in
`~/.claude/.credentials.json`. Diese Dateien dürfen nicht kopiert,
veröffentlicht oder eingecheckt werden; die `deny`-Regeln der
Autonomie-Konfiguration halten die Agenten zusätzlich davon ab, sie zu lesen.

## OpenRouter für Codex

Zusätzlich zur Codex-CLI-Anmeldung kann ein OpenRouter-API-Key als manueller
Fallback hinterlegt werden:

```bash
devbox openrouter setup
devbox openrouter status
```

Die Einrichtung fragt den Key verdeckt und ein OpenRouter-Modell ab. Ohne
Modellangabe wird `~openai/gpt-latest` verwendet. Der Key liegt ausschließlich
in `~/.config/devbox/openrouter.env` mit Dateimodus `0600`; Statusausgaben
zeigen seinen Wert nie an. Der normale Aufruf `codex` nutzt weiterhin die
ChatGPT-Anmeldung und damit zunächst das im ChatGPT-Abo enthaltene
Codex-Kontingent. OpenRouter wird erst mit dem separaten Befehl gestartet:

```bash
codex-openrouter
```

Dieser Befehl startet Codex über das Profil
`~/.codex/openrouter.config.toml` mit dem OpenRouter-Endpunkt und der Responses
API. Codex unterstützt derzeit keinen nahtlosen automatischen Providerwechsel
nach Erreichen des ChatGPT-Limits; der Wechsel erfolgt deshalb bewusst manuell.

Die OpenRouter-Einrichtung lässt sich einschließlich des gespeicherten Keys
wieder entfernen:

```bash
devbox openrouter disable
```

Dabei werden der gespeicherte Key, das Profil und `codex-openrouter` entfernt.
Der normale `codex`-Aufruf und seine ChatGPT-Anmeldung bleiben unverändert.

## Claude CLI

Die Claude-CLI (`@anthropic-ai/claude-code`) wird gleichwertig neben Codex
installiert:

```bash
claude --version
claude
```

Die Anmeldung erfolgt über `devbox auth login` (siehe oben) oder direkt mit
`claude auth login`. `devbox doctor` meldet den Anmeldestatus beider Agenten.

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
devbox remote-info
```

Ohne SSH bleibt die Devbox vollständig über die Konsole des LXC-Hosts (z. B.
`pct enter`, `lxc exec`, `incus exec`) und `sudo -iu dev` nutzbar.

## PostgreSQL

Der Installer legt die lokale Entwicklungsdatenbank `devbox` und die Rolle
`dev` mit einem zufälligen Passwort an. Die Zugangsdaten liegen ausschließlich
im Container:

```text
/home/dev/.pgpass
/home/dev/.config/devbox/postgres.env
```

Beide Dateien gehören `dev` und haben Modus `0600`. Für ein Phoenix-Projekt
kann die Umgebung beispielsweise so geladen werden:

```bash
set -a
source ~/.config/devbox/postgres.env
set +a
```

Ein `devbox update` ändert das gespeicherte Datenbankpasswort nicht,
solange `postgres.env` bereits existiert.

## Betrieb und Updates

Diagnose:

```bash
devbox doctor
```

`update` muss als `root` laufen, nicht über `sudo` als `dev` – der Benutzer
`dev` besitzt bewusst kein allgemeines passwortloses `sudo`, sondern nur für
`ssh setup`/`ssh disable` und `packages install` (siehe oben). Auf der
Root-Konsole des Containers (z. B. direkt nach `pct enter <CTID>`, ohne
vorheriges `sudo -iu dev`) auf den aktuellen Stand des `master`-Branches
aktualisieren:

```bash
devbox update
```

Optional lässt sich auch ein anderer Branch installieren, zum Beispiel um
eine Vorabversion zu testen:

```bash
devbox update feature/mein-branch
```

`devbox update [branch]` lädt `install.sh` vom angegebenen (oder
standardmäßig dem `master`-) Branch aus dem GitHub-Repository herunter und
führt es erneut aus. Der Installer ist für wiederholte Ausführungen
ausgelegt: Betriebssystempakete, Codex CLI, Claude CLI und die verwaltete
Erlang-/Elixir-/Phoenix-Toolchain werden aktualisiert, während Workspace,
SSH-Schlüssel, Codex-Anmeldedaten, Git-Konfiguration, eine bereits vorhandene
`~/.codex/config.toml` und die PostgreSQL-Daten unverändert erhalten bleiben.

Um von einem eigenen Fork oder Spiegel zu aktualisieren, kann die
Repository-URL überschrieben werden:

```bash
DEVBOX_REPO_URL="https://raw.githubusercontent.com/<fork>/Scripts" \
  devbox update <branch>
```

Automatische Sicherheitsupdates sind zusätzlich aktiviert, sodass
Betriebssystem-Patches auch ohne manuelles `devbox update` einlaufen.

## Versionsmanifest und Prüfsummen

Alle aktiv verwalteten Tool-Versionen sind zentral in
[`versions.env`](versions.env) definiert (DevBox selbst, Node.js,
Erlang/OTP, Elixir, Phoenix, Codex CLI, Claude Code, Happy). `install.sh`
bleibt ein einzelnes, per `curl | bash` ausführbares Skript und trägt dieselben
Werte als eingebettete Defaults; ein Regressionstest stellt sicher, dass beide
Stellen nicht auseinanderlaufen. Keine der verwalteten npm-Komponenten nutzt
`@latest`. Jeder Wert lässt sich für einen einzelnen Lauf per Umgebungsvariable
überschreiben, zum Beispiel `ERLANG_VERSION=28.4 bash install.sh`.

```bash
devbox version
```

Die heruntergeladenen Erlang/OTP- und Elixir-Artefakte werden vor der
Installation gegen bekannte SHA256-Prüfsummen aus
[`checksums.env`](checksums.env) verifiziert; ein manipuliertes oder falsches
Artefakt bricht die Installation sofort ab, bevor es entpackt wird.

## Tests

Lokale Prüfungen, aus diesem Verzeichnis heraus:

```bash
bash -n install.sh bin/devbox.sh lib/common.sh tests/test-devbox.sh

bash tests/test-devbox.sh

shellcheck -x --exclude=SC1090,SC1091,SC2086,SC2154 \
  install.sh \
  bin/devbox.sh \
  lib/common.sh \
  tests/test-devbox.sh
```

> **Hinweis:** Die CI verwendet die ShellCheck-Version aus dem
> Ubuntu-Paketarchiv (derzeit 0.9.0). Neuere Versionen melden teilweise
> andere Prüfcodes, weshalb `# shellcheck disable=…`-Kommentare beide
> Varianten abdecken.

Diese Prüfungen laufen bei Pushes und Pull Requests über GitHub Actions. Ein
vollständiger End-to-End-Test erfordert weiterhin einen echten LXC-Container,
weil Paketinstallation, Systemd-Dienste und PostgreSQL lokal nicht realistisch
simuliert werden können.

## Upstream-Dokumentation

- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex `AGENTS.md`](https://developers.openai.com/codex/guides/agents-md/)
- [Claude Code](https://code.claude.com/docs/en/overview)
- [Claude Code: Berechtigungsmodi](https://code.claude.com/docs/en/permission-modes)
- [Claude Code: settings.json](https://code.claude.com/docs/en/settings)
- [ChatGPT Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [Erlang/OTP Builds (hex.pm)](https://builds.hex.pm/)
- [Phoenix installation](https://hexdocs.pm/phoenix/installation.html)
