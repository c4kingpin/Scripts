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
Erlang/Elixir, Codex/Claude/Happy oder Kisuke) nach.

Betriebslogik, die `install.sh` erst nach seiner Bootstrap-Phase (Root-/OS-/
Netzwerk-Check) braucht, wandert schrittweise in eigene, ebenfalls
nachgeladene Module unter [`lib/`](lib) und [`features/`](features):
[`lib/common.sh`](lib/common.sh) (Checksum-Verifikation, `run_as_dev`-Helfer)
und [`lib/user.sh`](lib/user.sh) (Dev-User-Anlage) sind quer genutzte
Bausteine; [`features/`](features) enthält je eine Datei pro
Installationsphase (`base.sh`, `node.sh`, `postgres.sh`, `agents.sh`,
`happy.sh`, `kisuke.sh`, `agent-notify.sh`, `tooling.sh`, `elixir.sh`). Jede Datei definiert nur Funktionen —
`install.sh` ruft sie in derselben Reihenfolge auf, in der die Phasen früher
inline standen. Die Bootstrap-Kette selbst bleibt bewusst in `install.sh`, da
sie gebraucht wird, um diese Module überhaupt herunterzuladen. `bin/devbox.sh`
bleibt davon unabhängig eine einzelne, in sich geschlossene Datei ohne
Laufzeit-Abhängigkeit auf `lib/`, damit `devbox`-Befehle nach der
Installation ohne Netzwerkzugriff funktionieren.

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
| Remote-Provider | `happy` |

Rein lesende Hilfsbefehle für den Workspace (kein Branch-Wechsel, keine
Commits, kein Löschen, kein automatisches Anlegen von `.env`):

```bash
devbox workspace list
devbox workspace doctor <project>
```

`workspace doctor` prüft nur, ob `<project>` unter dem Workspace existiert,
ein Git-Repository ist und eine `.env`-Datei vorhanden ist.

Installiert werden unter anderem Codex CLI, Claude CLI, Node.js 24, Git, Git
LFS, GitHub CLI, Python, ShellCheck, ripgrep, `fd`, Erlang/OTP, Elixir,
Phoenix und PostgreSQL.

### Feature-Auswahl

`base` (OS-Pakete, Git/GitHub-CLI), `agents` (Codex/Claude), Node.js
und `mise` bilden den Kern jeder DevBox — ohne sie wäre es keine
Agenten-Laufzeitumgebung mehr und sie sind daher immer Teil der Installation.
Die beiden schweren, projektspezifischen Laufzeiten lassen sich abwählen,
`redis` ist rein optional und in keinem Profil standardmäßig aktiv:

| Feature | Inhalt | Standardmäßig aktiv |
| --- | --- | --- |
| `elixir` | Erlang/OTP, Elixir, Phoenix | im `default`-Profil |
| `postgres` | PostgreSQL-Paket, -Dienst, Dev-Rolle/-Datenbank | im `default`-Profil |
| `redis` | Redis-Server, systemd-Dienst | nie — nur per `DEVBOX_FEATURES` |

In einem echten Terminal (nicht `curl | bash`) fragt der Installer diese
Auswahl interaktiv ab, sofern weder `DEVBOX_PROFILE` noch `DEVBOX_FEATURES`
gesetzt sind — siehe den Hinweis zu den interaktiven Dialogen im Abschnitt
[Installation](#installation). Für nicht interaktive Installationen (oder um
die Frage zu überspringen) per Umgebungsvariable vorgeben:

Standardmäßig (`DEVBOX_PROFILE=default`, oder gar nicht gesetzt) sind `elixir`
und `postgres` aktiv, `redis` nicht. Ein schlankeres Profil ohne `elixir` und
`postgres`:

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env DEVBOX_PROFILE=minimal bash
```

Oder gezielt einzelne Features an-/abwählen (überschreibt das Profil
vollständig):

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env DEVBOX_FEATURES=postgres bash
```

Oder `redis` zusätzlich zum Standardprofil aktivieren:

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env DEVBOX_FEATURES=elixir,postgres,redis bash
```

Die getroffene Auswahl landet in
`~/.config/devbox/features` und wird von `devbox doctor` gelesen, damit dort
keine falschen Warnungen für bewusst nicht installierte Features auftauchen.

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

Die DevBox setzt **Ubuntu 24.04 LTS** voraus (22.04 funktioniert ebenfalls);
amd64 und arm64 werden unterstützt. Der Installer prüft das zu Beginn und
bricht mit einer klaren Meldung ab, falls ein anderes System läuft.

Ubuntu 20.04 wird **nicht** unterstützt: für OTP 29.0.5 existiert kein
passendes vorkompiliertes Artefakt für 20.04, das Standardprofil würde dort
also grundsätzlich fehlschlagen.

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

> **Hinweis zu den interaktiven Dialogen:** Bei `curl | bash` ist die
> Standardeingabe mit der Pipe belegt, daher kann das Skript in diesem Fall
> **nicht** interaktiv nachfragen und verwendet für jeden Parameter, der
> nicht explizit per Umgebungsvariable vorgegeben wurde, den jeweiligen
> Standardwert. Für die interaktiven Dialoge das Skript zuerst
> herunterladen und dann als Datei ausführen:
>
> ```bash
> curl -fsSL -o install.sh \
>   https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh
> bash install.sh
> ```

Ausgeführt in einem echten Terminal fragt das Skript vor der eigentlichen
Installation alle Konfigurationsparameter nacheinander ab — sofern der
jeweilige Wert nicht schon per Umgebungsvariable gesetzt wurde, überspringt
das Skript die zugehörige Frage:

1. **Optionale Laufzeiten** (`DEVBOX_PROFILE`/`DEVBOX_FEATURES`, siehe
   [Feature-Auswahl](#feature-auswahl)) — Standard, Minimal oder
   Custom-Auswahl einzelner Features.
2. **Remote-Provider** (`DEVBOX_REMOTE`, siehe
   [Remote-Provider](#remote-provider)) — Happy oder kein Remote-Zugriff.
3. **Agenten-Autonomie** (`DEVBOX_AUTONOMY`, siehe unten).

Die Auswahl bei der Autonomie-Frage gilt für Codex und Claude gemeinsam —
ein Profil, beide Agenten verhalten sich gleich:

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
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env DEVBOX_AUTONOMY=autonomous bash
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
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... client" bash
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

## Remote-Provider

Codex und Claude bilden zusammen mit der lokalen Entwicklungsumgebung den
Kern der DevBox. Remote-Zugriff ist optional und wird über einen
konfigurierbaren Remote-Provider bereitgestellt. Standardmäßig wird Happy
verwendet. In einem echten Terminal fragt der Installer diese Auswahl
interaktiv ab, sofern `DEVBOX_REMOTE` nicht gesetzt ist — siehe den Hinweis
zu den interaktiven Dialogen im Abschnitt [Installation](#installation). Per
Umgebungsvariable vorgegeben:

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env DEVBOX_REMOTE=happy bash
```

Alternativ steht [Kisuke Connect](https://kisuke.dev) als Remote-Provider
zur Verfügung:

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env DEVBOX_REMOTE=kisuke bash
```

Ohne Remote-Provider installiert der Installer weder Happy noch Kisuke und
richtet auch keinen zugehörigen Dienst ein; erreichbar bleibt die Box dann
über die Host-Konsole (`pct enter`, `lxc exec`, `incus exec`) und optional
SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/c4kingpin/Scripts/master/devbox/install.sh |
  env DEVBOX_REMOTE=none bash
```

Die getroffene Auswahl landet in `/var/lib/devbox/remote-provider`,
erscheint in `devbox status` und `devbox doctor --json`
(`remote_provider`), und `devbox update` übernimmt sie automatisch —
ein Update ändert den konfigurierten Provider nicht. Bestehende
Installationen ohne gespeicherte Auswahl (vor diesem Feature) werden beim
nächsten Update automatisch als `happy` interpretiert; Happy-Pairing,
-Credentials und -Dienst bleiben dabei unverändert erhalten.

SSH ist davon unabhängig: es ist immer ein separater, optionaler
Zugangsweg und insbesondere als Recovery-/Fallback-Zugang nutzbar, falls
der konfigurierte Remote-Provider nicht verfügbar ist.

Kisuke Connect ist als npm-Paket `@kisuke/cli` installiert (Binary `kisuke`)
und bringt eine eigene Terminal-/Editor-/Chat-Oberfläche in der Kisuke-App
mit; anders als Happy stellt es keine `happy claude`/`happy codex`-Wrapper
bereit — Codex und Claude werden dort direkt aufgerufen. Die Einrichtung
läuft headless über `kisuke connect --headless` (siehe
[Kisuke-Daemon nach dem Booten](#kisuke-daemon-nach-dem-booten) unten für
Details zum Boot-Verhalten): der Befehl druckt eine URL, die auf einem
anderen Gerät geöffnet wird, ein lokaler Browser ist auf der DevBox nicht
nötig (vgl. [Anmeldung der Agenten](#anmeldung-der-agenten) oben).

## Happy-Daemon nach dem Booten

Nur relevant, wenn Happy als Remote-Provider aktiv ist (Standard). Happy
muss dafür ohne interaktiven Login verfügbar sein. Der Installer richtet
dafür den systemd-Dienst
`devbox-happy-daemon.service` ein:

```bash
systemctl status devbox-happy-daemon.service
```

Der Dienst läuft als Benutzer `dev` mit `HOME=/home/dev`, startet erst nach
`network-online.target` und ruft ein Guard-Skript unter
`/usr/local/lib/devbox/happy-daemon-start.sh` auf. Das Skript startet den
Daemon nur, wenn Happy installiert, bereits gekoppelt (`access.key`,
`settings.json` mit `machineId`) und noch nicht aktiv ist. Alle anderen Fälle
enden bewusst mit Exit-Code 0 (`Restart=no`), damit eine noch nicht
eingerichtete DevBox keinen fehlgeschlagenen oder dauerhaft neu startenden
Dienst hinterlässt. Bestehende Happy-Credentials und die Maschinen-
Registrierung werden dabei nicht verändert.

Nach einem Reboot ist damit kein `sudo -iu dev` mehr nötig, damit die DevBox
in der Happy-App erscheint. Die ältere Startlogik in der `.bashrc` von `dev`
bleibt als Fallback bestehen, falls der Dienst auf einer Box fehlt oder
deaktiviert wurde.

`devbox auth status` und `devbox doctor` melden zusätzlich, ob der Dienst
installiert und aktiviert ist.

## Kisuke-Daemon nach dem Booten

Nur relevant, wenn Kisuke als Remote-Provider aktiv ist (`DEVBOX_REMOTE=kisuke`).
Anders als bei Happy schreibt DevBox hierfür keinen eigenen systemd-Dienst:
Kisuke Connect verwaltet seinen Daemon selbst, über einen systemd-`--user`-
Dienst namens `kisuke` (Standard-Service-Level `user`), den `kisuke connect`
beim ersten `devbox auth login` selbst anlegt und startet:

```bash
systemctl --user status kisuke
```

Ein frischer LXC-Container hat aber noch nie ein interaktives Login gesehen
und damit auch keine laufende D-Bus-User-Session — `systemctl --user` liefe
ohne weiteres Zutun ins Leere, und `kisuke connect`/`kisuke login` kämen
dadurch nicht einmal bis zur Anmelde-URL (der Daemon-Vordergrundmodus
`kisuke run` beendet sich bei fehlender Anmeldung sofort wieder, und die
Login-Guided-Setup-Flow braucht selbst einen bereits erreichbaren Daemon).
Der Installer behebt genau das mit einem Einzeiler:

```bash
loginctl enable-linger dev
```

Das lässt systemd unabhängig von jedem Login eine persistente
User-Session (`user@<uid>.service`) inklusive D-Bus-Bus für `dev` starten —
der Standardweg für genau diesen Anwendungsfall. Mit dieser Session
funktioniert Kisukes eigener, für Server/Headless-Umgebungen vorgesehener
Einrichtungspfad zuverlässig, ohne dass DevBox einen eigenen
Daemon-Wrapper nachbauen muss.

`devbox auth login` ruft dafür `kisuke connect --headless` auf: der Befehl
installiert und startet den `kisuke`-Dienst und schließt die Anmeldung in
einem Schritt ab (URL öffnen, kein lokaler Browser nötig). Ein
`kisuke`-Dienst, der noch nicht existiert, ist auf einer frisch
installierten, noch nicht angemeldeten Box der erwartete Zustand, keine
Störung.

Nach einem Reboot ist damit kein `sudo -iu dev` mehr nötig, damit die DevBox
in der Kisuke-App erscheint. Die ältere Startlogik in der `.bashrc` von `dev`
bleibt als Fallback bestehen, falls der Dienst in einem Boot einmal nicht von
selbst hochkommt (`systemctl --user start kisuke`).

`devbox auth status` und `devbox doctor` melden zusätzlich, ob der Dienst
installiert und aktiviert ist; die Authentifizierungsprüfung selbst läuft
über `kisuke whoami`, da Kisukes Datenformat unter `~/.kisuke` — anders als
bei Happy — nicht dokumentiert ist.

## Push-Benachrichtigung bei Claude-/Codex-Limit

Erreicht eine über Happy laufende Claude- oder Codex-Session ein Usage-/
Rate-Limit, schickt der Installer dafür automatisch eine Happy-Push-
Benachrichtigung, statt die Session einfach kommentarlos stehen zu lassen:

- **Claude** meldet sich strukturiert über den `StopFailure`-Hook (feuert nur
  bei einem echten API-Fehler, nie bei einem normalen Stop) mit
  `matcher: "rate_limit|billing_error"` in `~/.claude/settings.json`.
- **Codex** kennt kein vergleichbares strukturiertes Signal; die
  `notify`-Konfiguration in `~/.codex/config.toml` prüft deshalb konservativ
  die letzte Assistant-Nachricht auf eindeutige Limit-Formulierungen (z. B.
  "usage limit", "rate limit reached") und bleibt bei Unsicherheit still.

Beide Detektoren rufen den gemeinsamen Mechanismus unter
`~/.local/bin/devbox-agent-limit-notify` auf, der die eigentliche
`happy notify` ausführt und pro Agent höchstens eine Benachrichtigung
innerhalb eines kurzen Zeitfensters verschickt. Ein bereits vorhandenes
`~/.codex/config.toml` bleibt wie gewohnt unangetastet — der Installer weist
dann nur mit einem Hinweis darauf hin, `notify` selbst zu ergänzen.

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

Teil des `postgres`-Features (siehe [Feature-Auswahl](#feature-auswahl)) —
bei `DEVBOX_PROFILE=minimal` oder `DEVBOX_FEATURES` ohne `postgres` entfällt
dieser Abschnitt. Standardmäßig legt der Installer die lokale
Entwicklungsdatenbank `devbox` und die Rolle `dev` mit einem zufälligen
Passwort an. Die Zugangsdaten liegen ausschließlich im Container:

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

Überblick, wie diese konkrete Box konfiguriert ist (Version, Profil,
Features, SSH, Agenten-Auth, GitHub, OpenRouter):

```bash
devbox status
```

`status` setzt sich aus den bereits bestehenden Einzelkommandos zusammen
(`ssh status`, `auth status`, `github status`, `openrouter status`) und
dupliziert deren Prüflogik nicht.

Diagnose:

```bash
devbox doctor
```

Dieselben Prüfungen maschinenlesbar für Agenten/Monitoring, mit Exit-Code
`0` (gesund) bzw. `1` (ungesund):

```bash
devbox doctor --json
```

`update`/`rollback` müssen als `root` laufen, nicht über `sudo` als `dev` –
der Benutzer `dev` besitzt bewusst kein allgemeines passwortloses `sudo`,
sondern nur für `ssh setup`/`ssh disable` und `packages install` (siehe
oben). Auf der Root-Konsole des Containers (z. B. direkt nach
`pct enter <CTID>`, ohne vorheriges `sudo -iu dev`) auf das neueste
veröffentlichte Release aktualisieren:

```bash
devbox update
```

Ohne Argumente lädt `devbox update` das neueste GitHub-Release herunter.
Vorab prüfen, ob überhaupt ein Update verfügbar ist, ohne etwas zu
installieren:

```bash
devbox update --check
```

Ein bestimmtes Release gezielt installieren:

```bash
devbox update --to v1.1.0
```

Für Entwicklung/Tests lässt sich weiterhin direkt von einem Branch
installieren (kein Versionsvergleich, keine Release-Voraussetzung):

```bash
devbox update --branch feature/mein-branch
# Kurzform: devbox update feature/mein-branch
```

Der Installer ist für wiederholte Ausführungen ausgelegt: Betriebssystem-
pakete, Codex CLI, Claude CLI und die verwaltete Erlang-/Elixir-/Phoenix-
Toolchain werden aktualisiert, während Workspace, SSH-Schlüssel, Codex-
Anmeldedaten, Git-Konfiguration, eine bereits vorhandene
`~/.codex/config.toml` und die PostgreSQL-Daten unverändert erhalten bleiben.

Die zuletzt aktive Version/Ref wird vor jedem Update in
`/var/lib/devbox/previous-version`/`previous-ref` vermerkt (siehe
[State-Modell](#state-modell)), sodass sich ein Update bei Bedarf
zurücknehmen lässt:

```bash
devbox rollback
```

`devbox rollback` installiert erneut genau den Installer-/Modul-Stand, der
vor dem letzten Update aktiv war — es nimmt **keine** OS-Paket-Upgrades,
PostgreSQL-Daten oder Workspace-Änderungen zurück.

Um von einem eigenen Fork oder Spiegel zu aktualisieren, kann die
Repository-URL überschrieben werden (die GitHub-Releases-API-Abfrage für
`--check`/das Standard-Update ohne `--to`/`--branch` bleibt dabei auf das
Haupt-Repository gerichtet, sofern nicht zusätzlich `DEVBOX_GITHUB_REPO`
gesetzt wird):

```bash
DEVBOX_REPO_URL="https://raw.githubusercontent.com/<fork>/Scripts" \
DEVBOX_GITHUB_REPO="<fork>/Scripts" \
  devbox update --branch <branch>
```

Automatische Sicherheitsupdates sind zusätzlich aktiviert, sodass
Betriebssystem-Patches auch ohne manuelles `devbox update` einlaufen.

## State-Modell

DevBox trennt persistenten Zustand nach Zuständigkeit:

| Bereich | Ort | Inhalt |
| --- | --- | --- |
| Root-State | `/var/lib/devbox/` | aktive Version (`version`), aktiver/vorheriger Ref (`active-ref`, `previous-ref`), installierter Commit (`commit`), gewählte optionale Features (`installed-features`), konfigurierter Remote-Provider (`remote-provider`), Installationsmetadaten (`install-state.json`) |
| User-State | `~/.config/devbox/` | Onboarding-Marker, OpenRouter-Konfiguration, benutzerbezogene Einstellungen |
| Fremdverwaltete Credentials | `~/.codex`, `~/.claude`, `~/.happy`, `~/.kisuke`, `~/.config/gh`, `~/.ssh` | jeweils ausschließlich vom zugehörigen Tool verwaltet |

Root-State wird ausschließlich von `install.sh`/`devbox update`/
`devbox rollback` (alle als `root`) geschrieben, ist aber für `dev` lesbar —
`devbox doctor` läuft ohne `sudo` und prüft beim Start, ob der aktive
Root-State zur laufenden Manager-Version passt.

## Versionsmanifest und Prüfsummen

Alle aktiv verwalteten Tool-Versionen sind zentral in
[`versions.env`](versions.env) definiert (DevBox selbst, Node.js,
Erlang/OTP, Elixir, Phoenix, Codex CLI, Claude Code, Happy, Kisuke).
`install.sh`
bleibt ein einzelnes, per `curl | bash` ausführbares Skript und trägt dieselben
Werte als eingebettete Defaults; ein Regressionstest stellt sicher, dass beide
Stellen nicht auseinanderlaufen. Keine der verwalteten npm-Komponenten nutzt
`@latest`. Jeder Wert lässt sich für einen einzelnen Lauf per Umgebungsvariable
überschreiben, zum Beispiel `ERLANG_VERSION=28.4 bash install.sh`.

```bash
devbox version
```

Maschinenlesbar für Agenten/Tooling:

```bash
devbox version --json
```

Da `master` nach einem Release neue Commits enthalten kann, ohne dass sich
`DEVBOX_VERSION` ändert, zeigen `devbox version` und `devbox status`
zusätzlich den tatsächlich installierten Commit (persistiert von
`install.sh`, sofern der Installationslauf ihn auflösen konnte —
andernfalls `unknown`). `devbox update --check` auf einem Branch vergleicht
diesen Commit gegen den aktuellen Stand des Branches, statt nur zu melden,
dass Branch-Updates "nicht versionsverglichen" sind.

Die heruntergeladenen Erlang/OTP- und Elixir-Artefakte werden vor der
Installation gegen bekannte SHA256-Prüfsummen aus
[`checksums.env`](checksums.env) verifiziert; ein manipuliertes oder falsches
Artefakt bricht die Installation sofort ab, bevor es entpackt wird.

## Tests

Lokale Prüfungen, aus diesem Verzeichnis heraus:

```bash
bash -n install.sh bin/devbox.sh lib/*.sh features/*.sh tests/*.sh

bash tests/test-devbox.sh

shellcheck -x --exclude=SC1090,SC1091 \
  install.sh \
  bin/devbox.sh \
  lib/*.sh \
  features/*.sh \
  tests/*.sh
```

> **Hinweis:** Die CI verwendet die ShellCheck-Version aus dem
> Ubuntu-Paketarchiv (derzeit 0.9.0). Neuere Versionen melden teilweise
> andere Prüfcodes, weshalb `# shellcheck disable=…`-Kommentare beide
> Varianten abdecken.

Diese Prüfungen laufen bei Pushes und Pull Requests über GitHub Actions
(`.github/workflows/ci.yml`) und installieren nichts — sie prüfen Syntax,
Stil und die im Text der Skripte erwartbaren Muster.

Ein vollständiger End-to-End-Test braucht einen echten LXC-Container, weil
Paketinstallation, Systemd-Dienste und PostgreSQL sich lokal nicht
realistisch simulieren lassen:

```bash
sudo bash tests/lxc-integration-test.sh
```

Installiert DevBox in einem frischen `ubuntu:24.04`-LXD-Container, prüft
`devbox doctor`, die Agenten-CLIs, die PostgreSQL-Verbindung und ein echtes
`mix phx.new`, führt den Installer ein zweites Mal aus und vergleicht
danach Version, Feature-Auswahl, PostgreSQL-Passwort und eine vorhandene
`~/.codex/config.toml` — der wichtigste Einzeltest ist Idempotenz: ein
zweiter Lauf darf nichts verändern, was bereits korrekt eingerichtet ist.
Braucht ein funktionierendes LXD auf dem ausführenden Host (`lxc launch`
muss funktionieren) und Root. Läuft nicht bei jedem Push/PR mit (dauert
durch echte Downloads/Installationen deutlich länger), sondern über
[`.github/workflows/lxc-integration.yml`](../.github/workflows/lxc-integration.yml)
nächtlich sowie jederzeit manuell:

```bash
gh workflow run lxc-integration.yml
```

## Upstream-Dokumentation

- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex `AGENTS.md`](https://developers.openai.com/codex/guides/agents-md/)
- [Claude Code](https://code.claude.com/docs/en/overview)
- [Claude Code: Berechtigungsmodi](https://code.claude.com/docs/en/permission-modes)
- [Claude Code: settings.json](https://code.claude.com/docs/en/settings)
- [ChatGPT Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [Erlang/OTP Builds (hex.pm)](https://builds.hex.pm/)
- [Phoenix installation](https://hexdocs.pm/phoenix/installation.html)
