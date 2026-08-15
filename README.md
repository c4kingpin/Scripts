# Codex DevBox für LXC

Dieses Repository enthält [`install.sh`](install.sh), einen eigenständigen
Installer für eine isolierte Codex- und Claude-Entwicklungsumgebung. Das
Skript läuft direkt **innerhalb** eines bereits vorhandenen, unprivilegierten
LXC-Containers (Proxmox VE, LXD/Incus oder jede andere Plattform), wird als
`root` ausgeführt und richtet dabei auch den `codex-devbox`-Manager ein. Es
hat keine Abhängigkeit zu Proxmox selbst oder zum Community-Scripts-Framework.

Das Skript erstellt oder konfiguriert den Container selbst nicht. Storage,
Netzwerk, Template und Ressourcen des Containers müssen vor dem Aufruf bereits
über das jeweilige Hypervisor-Tooling (`pct create`, `lxc launch`,
`incus launch`, …) vorhanden sein.

## Standardkonfiguration

| Einstellung | Standard |
| --- | --- |
| Benutzer | `dev` |
| Workspace | `/home/dev/workspace` |
| Codex-Autonomie | ausgewogen |

Installiert werden unter anderem Codex CLI, Claude CLI, Node.js 24, Git, Git
LFS, GitHub CLI, Python, ShellCheck, ripgrep, `fd`, Erlang/OTP, Elixir,
Phoenix und PostgreSQL. Erlang, Elixir und Phoenix werden für den Benutzer
`dev` über `mise` verwaltet.

Empfohlene Containergröße: 4 CPU-Kerne, 8192 MiB RAM, 32 GiB Speicher, Debian
13 (amd64), unprivilegiert. Kleinere Container funktionieren ebenfalls, der
Erlang-Quellbuild profitiert aber von mehr CPU-Kernen.

## Installation

Zuerst einen unprivilegierten LXC-Container mit Debian 13 (oder einem anderen
Debian-/Ubuntu-Derivat mit `apt`) über das jeweilige Hypervisor-Tooling
anlegen und starten. Danach das Skript als `root` **innerhalb** des
Containers ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/install.sh | bash
```

Auf Proxmox VE zum Beispiel über die Konsole des Containers:

```bash
pct enter <CTID>
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/install.sh | bash
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
>   https://raw.githubusercontent.com/c4kingpin/Scripts/master/install.sh
> bash install.sh
> ```

Ausgeführt in einem echten Terminal fragt das Skript dann vor der eigentlichen
Installation, wie autonom Codex arbeiten darf:

| Profil | Codex-Verhalten |
| --- | --- |
| Kontrolliert | Nur lesender Zugriff; Änderungen und Befehle benötigen eine Freigabe. |
| Ausgewogen (Standard) | Codex darf den Workspace selbstständig bearbeiten und fragt für Zugriffe außerhalb des Workspace oder auf das Netzwerk. |
| Autonom | Codex darf den Workspace bearbeiten und das Netzwerk ohne Freigabedialoge nutzen; die Workspace-Sandbox bleibt aktiv. |
| Vollzugriff | Keine Sandbox und keine Freigabedialoge innerhalb des LXC-Containers. |

Ohne interaktives Terminal (also auch beim `curl | bash`-Einzeiler) wird
`balanced` verwendet, sofern nicht explizit ein Profil vorgegeben wird:

```bash
CODEX_AUTONOMY=autonomous \
  curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/install.sh | bash
```

Gültige Werte sind `controlled`, `balanced`, `autonomous` und `full-access`.
`full-access` hebt nur die innere Codex-Sandbox auf; die Grenze des
unprivilegierten LXC-Containers bleibt bestehen.

Die Auswahl wird als `approval_policy` und `sandbox_mode` in
`/home/dev/.codex/config.toml` gespeichert und kann dort später jederzeit
geändert werden. Ein späterer `codex-devbox update` überschreibt eine bereits
vorhandene `config.toml` nicht.

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

SSH bleibt deaktiviert, solange kein Public Key hinterlegt ist. Ein Key kann
entweder vorab beim Installationsaufruf übergeben werden:

```bash
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... client" \
  curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/install.sh | bash
```

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
nicht kopiert, veröffentlicht oder eingecheckt werden.

## OpenRouter für Codex

Zusätzlich zur Codex-CLI-Anmeldung kann ein OpenRouter-API-Key als manueller
Fallback hinterlegt werden:

```bash
codex-devbox openrouter setup
codex-devbox openrouter status
```

Die Einrichtung fragt den Key verdeckt und ein OpenRouter-Modell ab. Ohne
Modellangabe wird `~openai/gpt-latest` verwendet. Der Key liegt ausschließlich
in `~/.config/codex-devbox/openrouter.env` mit Dateimodus `0600`; Statusausgaben
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
codex-devbox openrouter disable
```

Dabei werden der gespeicherte Key, das Profil und `codex-openrouter` entfernt.
Der normale `codex`-Aufruf und seine ChatGPT-Anmeldung bleiben unverändert.

## Claude CLI

Neben Codex installiert der Installer auch die Claude-CLI
(`@anthropic-ai/claude-code`) für den Benutzer `dev`:

```bash
claude --version
claude
```

Der erste Aufruf von `claude` führt durch die Anmeldung (Browser-Login oder
ein hinterlegter `ANTHROPIC_API_KEY`). Die Anmeldedaten verwaltet die CLI
selbst; sie werden vom Installer weder ausgegeben noch verändert.

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

Ohne SSH bleibt die Devbox vollständig über die Konsole des LXC-Hosts (z. B.
`pct enter`, `lxc exec`, `incus exec`) und `sudo -iu dev` nutzbar.

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

Ein `codex-devbox update` ändert das gespeicherte Datenbankpasswort nicht,
solange `postgres.env` bereits existiert.

## Betrieb und Updates

Diagnose:

```bash
codex-devbox doctor
```

`update` muss als `root` laufen, nicht über `sudo` als `dev` – der Benutzer
`dev` besitzt bewusst kein allgemeines passwortloses `sudo`, sondern nur für
`ssh setup`/`ssh disable` (siehe oben). Auf der Root-Konsole des Containers
(z. B. direkt nach `pct enter <CTID>`, ohne vorheriges `sudo -iu dev`) auf den
aktuellen Stand des `master`-Branches aktualisieren:

```bash
codex-devbox update
```

Optional lässt sich auch ein anderer Branch installieren, zum Beispiel um
eine Vorabversion zu testen:

```bash
codex-devbox update feature/mein-branch
```

`codex-devbox update [branch]` lädt `install.sh` vom angegebenen (oder
standardmäßig dem `master`-) Branch aus dem GitHub-Repository herunter und
führt es erneut aus. Der Installer ist für wiederholte Ausführungen
ausgelegt: Betriebssystempakete, Codex CLI, Claude CLI und die verwaltete
Erlang-/Elixir-/Phoenix-Toolchain werden aktualisiert, während Workspace,
SSH-Schlüssel, Codex-Anmeldedaten, Git-Konfiguration, eine bereits vorhandene
`~/.codex/config.toml` und die PostgreSQL-Daten unverändert erhalten bleiben.

Um von einem eigenen Fork oder Spiegel zu aktualisieren, kann die
Repository-URL überschrieben werden:

```bash
CODEX_DEVBOX_REPO_URL="https://raw.githubusercontent.com/<fork>/Scripts" \
  codex-devbox update <branch>
```

Automatische Sicherheitsupdates sind zusätzlich aktiviert, sodass
Betriebssystem-Patches auch ohne manuelles `codex-devbox update` einlaufen.

## Tests

Lokale Prüfungen:

```bash
bash -n install.sh tests/test-codex-devbox.sh

bash tests/test-codex-devbox.sh

shellcheck -x --exclude=SC1090,SC1091,SC2086,SC2154 \
  install.sh \
  tests/test-codex-devbox.sh
```

Diese Prüfungen laufen bei Pushes und Pull Requests über GitHub Actions. Ein
vollständiger End-to-End-Test erfordert weiterhin einen echten LXC-Container,
weil Paketinstallation, Systemd-Dienste und PostgreSQL lokal nicht realistisch
simuliert werden können.

## Upstream-Dokumentation

- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex `AGENTS.md`](https://developers.openai.com/codex/guides/agents-md/)
- [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
- [ChatGPT Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [mise](https://mise.jdx.dev/)
- [Phoenix installation](https://hexdocs.pm/phoenix/installation.html)
