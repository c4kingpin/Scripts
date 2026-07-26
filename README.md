# Codex Dev Box

Interaktiver Installer für eine unprivilegierte Ubuntu-24.04-LXC-Devbox auf
Proxmox VE. Das Skript richtet SSH-Public-Key-Zugriff, Node.js, Python,
Git-Werkzeuge, die Codex CLI und optionales Remote Control mit persistentem
Autostart ein.

## Voraussetzungen

- Proxmox VE 8 oder neuer auf einem `amd64`-Host
- Ausführung als `root` direkt auf dem Proxmox-VE-Host
- interaktives Terminal
- aktive Proxmox-Storages für `rootdir` und `vztmpl`
- vorhandene Linux-Bridge, standardmäßig `vmbr0`
- Internetzugriff für Host und Container
- öffentlicher SSH-Schlüssel
- für Remote Control: ChatGPT-Konto und Workspace mit Codex-Zugriff sowie ein
  unterstützter ChatGPT-Remote-Client

## Verwendung

```bash
bash ./codex-devbox.sh
```

Der Standardmodus erstellt einen Container mit 4 CPU-Kernen, 8 GiB RAM,
512 MiB Swap, 32 GiB Disk und DHCP. Im erweiterten Modus lassen sich
Ressourcen, Storages, Netzwerk und SSH-Agent-Forwarding konfigurieren. Für
manuelle Werte gelten mindestens 2 GiB RAM und 16 GiB Disk. Statische
IPv4-Konfigurationen benötigen eine nutzbare Host-Adresse und ein Gateway im
selben `/1`- bis `/30`-Subnetz.

Für reproduzierbare Installationen kann eine konkrete Codex-Version gesetzt
werden. Standard ist die aktuelle LTS-Linie Node.js 24; Node.js 22 bleibt als
Maintenance-LTS-Option verfügbar:

```bash
CODEX_RELEASE=0.145.0 NODE_MAJOR=24 bash ./codex-devbox.sh
```

Remote Control einschließlich manuellem Pairing benötigt mindestens Codex
`0.143.0`. Eine explizit gesetzte ältere oder gleich alte Vorabversion wird
bereits vor der Container-Erstellung abgelehnt. Die Codex CLI kennzeichnet
`remote-control` derzeit noch als experimentell; der Installer prüft die
Funktion deshalb zusätzlich nach der Installation.

Weitere Optionen:

```bash
bash ./codex-devbox.sh --help
bash ./codex-devbox.sh --version
```

## Remote-Control-Onboarding

Beim ersten interaktiven SSH-Login bietet die Devbox die Remote-Control-
Einrichtung an. Sie wird bewusst erst nach der Provisionierung ausgeführt,
damit weder ChatGPT-Zugangsdaten noch Pairing-Codes im Proxmox-
Installationslog landen.

Der Ablauf:

1. Die Devbox prüft mit `codex login status`, ob Codex angemeldet ist.
2. Falls nötig, startet `codex login --device-auth` den für headless Systeme
   vorgesehenen OAuth-Gerätecode-Flow.
3. Nach erfolgreicher Anmeldung aktiviert die Devbox
   `codex-remote-control.service` als `systemd`-Benutzerdienst.
4. `codex remote-control pair` erzeugt einen kurzlebigen Pairing-Code.
5. Der Benutzer verbindet damit den Remote-Client im selben ChatGPT-Konto und
   Workspace.

Die Einrichtung kann beim ersten Login zurückgestellt und jederzeit erneut
gestartet werden:

```bash
codex-devbox-onboarding --pair
```

Verwaltung und Diagnose:

```bash
codex-devbox-onboarding --status
codex-devbox-onboarding --pair
codex-devbox-onboarding --disable
journalctl --user -u codex-remote-control.service -n 100
```

Der Dienst läuft als Entwickler-Benutzer im Vordergrund unter Kontrolle von
`systemd --user`. User-Linger hält den Benutzerdienst auch ohne aktive
SSH-Sitzung verfügbar; zusammen mit dem bereits gesetzten Proxmox-Parameter
`onboot=1` startet Remote Control nach einem Host- oder Container-Neustart
automatisch. Vor der ersten erfolgreichen Anmeldung und Einrichtung bleibt der
Dienst deaktiviert.

Remote Control benötigt eine ChatGPT-Anmeldung mit Codex-Zugriff. Eine
vorhandene API-Key-Anmeldung kann lokale Codex-Aufgaben ausführen, erfüllt aber
nicht zwingend die ChatGPT-Workspace-Voraussetzungen für Remote Control. In
diesem Fall:

```bash
codex logout
codex-devbox-onboarding --pair
```

Das Onboarding speichert selbst keine Tokens. Codex verwaltet die Anmeldung in
seinem Auth-Cache; eine vorhandene `~/.codex/auth.json` wird auf Modus `0600`
gesetzt. Diese Datei enthält Zugangsdaten und darf weder kopiert noch
eingecheckt werden. Das Abmelden mit `codex logout` entfernt die Codex-
Anmeldung. Anschließend sollte Remote Control deaktiviert oder das Onboarding
nach einer erneuten Anmeldung wiederholt werden.

Workspace-Administratoren können Remote Control deaktivieren oder zusätzliche
SSO-, MFA- beziehungsweise Passkey-Schritte verlangen. Die Devbox öffnet keinen
App-Server-Port im Netzwerk; App-Server-Transporte sollten nicht direkt in ein
öffentliches oder gemeinsam genutztes Netz veröffentlicht werden.

Remote-Sitzungen übernehmen die lokalen Berechtigungen der Devbox. Da der
Entwickler-Benutzer passwortloses `sudo` besitzt, dürfen ausschließlich
vertrauenswürdige Geräte gekoppelt werden. Nicht mehr verwendete Verbindungen
sollten im Remote-Client entfernt und der Dienst auf der Devbox mit
`codex-devbox-onboarding --disable` abgeschaltet werden.

Offizielle Details:

- [Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [Authentication](https://learn.chatgpt.com/docs/auth)
- [`codex remote-control`](https://learn.chatgpt.com/docs/developer-commands#codex-remote-control)

## Sicherheitsprofil

- unprivilegierter LXC-Container
- ausschließlich SSH-Public-Key-Authentifizierung
- Root-Login, Passwort-Login, X11-Forwarding und SSH-Tunnel deaktiviert
- SSH-Agent-Forwarding standardmäßig deaktiviert
- effektive SSH-Konfiguration wird vor dem Dienststart mit `sshd -T` geprüft
- automatische Sicherheitsupdates aktiviert
- NodeSource-Schlüssel wird vor der Verwendung gegen seinen Fingerprint
  geprüft
- Codex wird über den offiziellen Standalone-Installer installiert; dieser
  verifiziert die heruntergeladenen Release-Artefakte per SHA-256
- Remote Control wird erst nach interaktiver ChatGPT-Anmeldung aktiviert und
  öffnet keinen öffentlichen Listener
- der Pairing-Code wird nur im Benutzerterminal ausgegeben, nicht im
  Installationslog
- Installationslogs liegen mit Modus `0600` unter
  `/var/log/codex-devbox/`

Der Entwickler-Benutzer besitzt absichtlich passwortloses `sudo`, damit Codex
Werkzeuge nachinstallieren kann. Die Devbox sollte deshalb als vertrauensarme
Arbeitsumgebung behandelt und nicht ohne zusätzliche Proxmox-Firewallregeln
direkt aus dem Internet erreichbar gemacht werden.

## Produktionsprüfungen

Vor der Erstellung prüft das Skript unter anderem:

- Proxmox-Version, Host-Architektur und benötigte Host-Werkzeuge
- Cluster-weite Verfügbarkeit der VMID, erneut unmittelbar vor `pct create`
- Bridge, Storage-Fähigkeiten und freien Speicherplatz
- Ressourcenuntergrenzen und vollständige Netzparameter
- DNS-Auflösung aller benötigten Ubuntu-, NodeSource- und Codex-Endpunkte
- Template-Architektur und Auswahl des neuesten Ubuntu-24.04-Templates

Nach der Provisionierung werden Node.js, npm, Git LFS, Python, ripgrep, `fd`,
Codex, die Remote-Control-CLI, Onboarding und User-Service, User-Linger,
passwortloses `sudo`, Workspace-Schreibzugriff, SSH-Dateirechte, SSH-Dienst und
APT-Timer verifiziert. Erst danach meldet der Installer Erfolg.

## Fehlerbehandlung

Bei einem Fehler nach der Container-Erstellung bleibt der unvollständige
Container zur Diagnose erhalten. Das Skript zeigt Logpfad und passende
`pct`-Befehle an. Fehler innerhalb des Containers enthalten den konkreten
Teilschritt und eine kompakte Kommandoangabe, ohne das gesamte Provisionierungs-
skript ins Terminal zu schreiben. Parallele Installationen werden durch ein
Host-Lock verhindert.

Ein fehlgeschlagener Container wird nicht fortgesetzt. Entferne ihn nach der
Diagnose mit den angezeigten `pct`-Befehlen und starte eine frische Installation.

## Betriebsintegration

Die Devbox lässt sich in vorhandene Proxmox-Firewall-, HA-, Backup- und
Monitoring-Konzepte integrieren. Eine vollständige End-to-End-Validierung
erfolgt auf einem Proxmox-Testhost.

## Tests

Die lokalen Tests benötigen Bash und OpenSSH:

```bash
bash ./tests/test-codex-devbox.sh
bash -n codex-devbox.sh tests/test-codex-devbox.sh
shellcheck -x codex-devbox.sh tests/test-codex-devbox.sh
```

Dieselben Prüfungen laufen bei jedem Push und Pull Request über GitHub Actions.
Ein vollständiger End-to-End-Test benötigt einen Proxmox-VE-Testhost, weil
Container-, Storage- und Netzwerkoperationen nicht lokal simuliert werden.

## Upstream-Dokumentation

- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Proxmox `pct`](https://pve.proxmox.com/pve-docs/pct.1.html)
- [Proxmox `pvesm`](https://pve.proxmox.com/pve-docs/pvesm.1.html)
- [Node.js Release-Status](https://nodejs.org/en/about/previous-releases)
- [NodeSource Distributions](https://github.com/nodesource/distributions)
