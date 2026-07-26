# Codex Dev Box

Interaktiver Installer für eine unprivilegierte Ubuntu-24.04-LXC-Devbox auf
Proxmox VE. Das Skript richtet SSH-Public-Key-Zugriff, Node.js, Python,
Git-Werkzeuge und die Codex CLI ein.

## Voraussetzungen

- Proxmox VE 8 oder neuer auf einem `amd64`-Host
- Ausführung als `root` direkt auf dem Proxmox-VE-Host
- interaktives Terminal
- aktive Proxmox-Storages für `rootdir` und `vztmpl`
- vorhandene Linux-Bridge, standardmäßig `vmbr0`
- Internetzugriff für Host und Container
- öffentlicher SSH-Schlüssel

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

Weitere Optionen:

```bash
bash ./codex-devbox.sh --help
bash ./codex-devbox.sh --version
```

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
Codex, passwortloses `sudo`, Workspace-Schreibzugriff, SSH-Dateirechte,
SSH-Dienst und APT-Timer verifiziert. Erst danach meldet der Installer Erfolg.

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
