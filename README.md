# Codex Dev Box

Interaktiver Installer für eine unprivilegierte Ubuntu-24.04-LXC-Devbox auf
Proxmox VE. Das Skript richtet SSH-Public-Key-Zugriff, Node.js, Python,
Git-Werkzeuge und die Codex CLI ein. Docker wird bewusst nicht installiert.

## Voraussetzungen

- Ausführung als `root` direkt auf einem Proxmox-VE-Host
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
Ressourcen, Storages, Netzwerk und SSH-Agent-Forwarding konfigurieren.

Für reproduzierbare Installationen kann eine konkrete Codex-Version gesetzt
werden. Unterstützt werden die LTS-Linien Node.js 22 und 24:

```bash
CODEX_RELEASE=0.143.0 NODE_MAJOR=22 bash ./codex-devbox.sh
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

## Fehlerbehandlung

Bei einem Fehler nach der Container-Erstellung bleibt der unvollständige
Container zur Diagnose erhalten. Das Skript zeigt Logpfad und passende
`pct`-Befehle an. Parallele Installationen werden durch ein Host-Lock
verhindert.

## Tests

Die lokalen Tests benötigen Bash und OpenSSH:

```bash
bash ./tests/test-codex-devbox.sh
bash -n codex-devbox.sh tests/test-codex-devbox.sh
shellcheck -x codex-devbox.sh tests/test-codex-devbox.sh
```

Ein vollständiger End-to-End-Test benötigt einen Proxmox-VE-Testhost, weil
Container-, Storage- und Netzwerkoperationen nicht lokal simuliert werden.

## Upstream-Dokumentation

- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Proxmox `pct`](https://pve.proxmox.com/pve-docs/pct.1.html)
- [Proxmox `pvesm`](https://pve.proxmox.com/pve-docs/pvesm.1.html)
- [Node.js Release-Status](https://nodejs.org/en/about/previous-releases)
- [NodeSource Distributions](https://github.com/nodesource/distributions)
