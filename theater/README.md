# Theater-PC auf Ubuntu 26.04 LTS

Dieses Verzeichnis enthält eine reproduzierbare Grundinstallation für einen
Theater-PC mit Linux Show Player, Spotify und einem per MIDI angesteuerten
MA Lightcommander 12/2. Die MIDI-Strecke läuft über ein **Lekato
USB-MIDI-Interface**, Audio über die vorhandene Soundkarte des Rechners.

Der Rechner erzeugt **kein DMX**. Er sendet nur MIDI-Befehle; der
Lightcommander speichert die Licht-Memories und steuert die DMX-Anlage selbst.

## Hardware

| Aufgabe | Gerät | Verbindung |
| --- | --- | --- |
| Licht-Cues | Lekato USB-MIDI-Interface | USB am PC, OUT-Kabel → MIDI IN des Lightcommander 12/2 |
| Ton | vorhandene Soundkarte | Line Out links/rechts → Tonmischpult |
| Ton (optional) | Focusrite Scarlett 18i20 (1. Gen) | USB am PC, Line Out 1/2 → Tonmischpult |

Das Scarlett ist kein Teil der Standardinstallation mehr. Wer es als
Audio-Interface einsetzt, ruft den Installer mit `--with-scarlett` auf; dann
wird `alsa-scarlett-gui` aus dem Quellcode gebaut. MIDI läuft auch in diesem
Fall über das Lekato-Interface.

## Installation

Das Skript als der vorgesehene Desktop-Benutzer ausführen. Es fordert bei
Bedarf `sudo` an, installiert Linux Show Player als Benutzer-Flatpak und legt
die Projektstruktur unter `~/Theater/` an.

```bash
git clone https://github.com/c4kingpin/Scripts.git
cd Scripts/theater
./install.sh --user theater --project Stueck_2026 --upgrade-system
```

`--upgrade-system` ist bewusst optional: Vor einer Aufführung sollten keine
ungetesteten Paket- oder Kernel-Updates eingespielt werden. Ohne die Option
installiert das Skript nur die benötigten Pakete und Anwendungen.

Das Skript läuft ausschließlich auf Ubuntu 26.04 LTS. Für einen Testlauf auf
einer anderen Version gibt es `--skip-release-check`; die Prüfung wird dann zur
Warnung.

Ein erneuter Aufruf ist grundsätzlich möglich. Bereits vorhandene Show- und
Dokumentationsdateien werden nicht überschrieben; `bin/midi-check.sh` und der
Autostart-Eintrag werden bei jedem Lauf aktualisiert. Ein vorhandener Quellbaum
von `alsa-scarlett-gui` wird unverändert weiterverwendet. Updates dieser
Software deshalb bewusst außerhalb einer laufenden Produktionsserie manuell
testen und durchführen.

## Was das Skript einrichtet

- Ubuntu-Tools: Flatpak, Snap, ALSA-Werkzeuge (`amidi`, `aconnect`),
  pulseaudio-utils und pavucontrol
- Linux Show Player (`org.linuxshowplayer.LinuxShowPlayer`) über Flathub
- Spotify als offizielles Snap-Paket
- USB-MIDI-Zugriff: Zielbenutzer in der Gruppe `audio`, Flatpak-Override
  `--device=all` für Linux Show Player, Sichtprüfung der MIDI-Ports
- Projektbaum `~/Theater/<Projekt>/{Show,Audio,Dokumentation,Backup,bin}`
  inklusive `bin/midi-check.sh`
- optional mit `--with-scarlett`: `alsa-scarlett-gui` aus dem offiziellen
  Quellrepository samt Build-Abhängigkeiten
- GNOME-Einstellungen gegen Bildschirm-Leerlauf, Suspend und
  Benachrichtigungsbanner
- optional mit `--kiosk`: Autologin, Update-Sperren, Härtung gegen
  Unterbrechungen und Autostart des Players (siehe unten)

Nach der Spotify-Installation zeigt der Installer die ALSA-Geräte und die
PulseAudio/PipeWire-Ausgänge an. Die vorgesehene Audioausgabe – die Soundkarte
oder, mit `--with-scarlett`, das Scarlett – muss dort als Ausgabegerät
erscheinen.

WLAN und Bluetooth bleiben in jedem Fall unangetastet: Spotify braucht Netz,
und ob Funk im Betrieb abgeschaltet wird, ist eine Entscheidung vor Ort.

Spotify kann mit `spotify` gestartet und anschließend mit einem persönlichen
Spotify-Konto angemeldet werden. Es ist für Pausen- und Hintergrundmusik
geeignet, aber nicht für ausfallsichere Aufführungs-Cues: Streaming,
Kontozugang, Werbung (Free-Konto) und mögliche App-Updates machen es weniger
vorhersehbar als lokal gespeicherte WAV-Dateien in Linux Show Player. Mit
`--skip-spotify` lässt sich die Installation auslassen.

## Autologin und Kiosk-Betrieb (`--kiosk`)

```bash
./install.sh --user theater --kiosk
```

**Autologin heißt ohne Passwort.** Wer physisch am Rechner ist, ist angemeldet.
Für einen Theater-PC in einer verschlossenen Technikkabine ist das die richtige
Abwägung; für ein Gerät im offenen Foyer nicht. Ist GDM nicht der
Display-Manager, überspringt das Skript diesen Teil mit einer Warnung, statt zu
raten.

`--kiosk` richtet ein:

| Bereich | Maßnahme |
| --- | --- |
| Anmeldung | `AutomaticLoginEnable` / `AutomaticLogin` in `/etc/gdm3/custom.conf` |
| Updates | `apt`-Periodik auf 0, `apt-daily`-Timer deaktiviert, `snap refresh --hold`, GNOME-Software-Downloads aus |
| Dialoge | apport (Crash-Dialoge) abgeschaltet, Sperrbildschirm und Bildschirmabdunklung aus |
| Fehlgriffe | Einschaltknopf ohne Funktion (GNOME und logind), Bildschirmleser samt Super+Alt+S aus |
| Datenträger | kein Dateifenster beim Anstecken eines USB-Sticks |
| Start | Autostart von Linux Show Player (ohne Showdatei) |

### Login-Keyring vor der ersten Vorstellung entsperren

Bei Autologin fragt GNOME Keyring beim Sitzungsstart nach dem Passwort des
Login-Keyrings – ein modaler Dialog genau dort, wo keiner sein darf. Spotify
legt seine Zugangsdaten dort ab, deshalb tritt das hier zuverlässig auf.

Einmalig im Programm **„Passwörter und Schlüssel"** für den Schlüsselbund
„Anmeldung" ein leeres Passwort setzen (Rechtsklick → Passwort ändern, neues
Passwort leer lassen) oder ihn löschen und neu anlegen. Das Skript automatisiert
das bewusst nicht: es würde ein Passwort im Klartext verarbeiten müssen.

### Updates zwischen zwei Produktionsserien

Mit `--kiosk` bleiben Sicherheitsupdates liegen – gewollt, denn ein Update
mitten in einer Serie ist das größere Risiko. Außerhalb der Spielzeit von Hand:

```bash
sudo snap refresh --unhold
sudo apt-get update && sudo apt-get full-upgrade
flatpak update --user
```

Danach die komplette Kette erneut durchtesten (Audio, MIDI, Memories) und
`sudo snap refresh --hold` wieder setzen.

### Härtung zurücknehmen

Jeder Eingriff liegt in einer eigenen Datei oder hat eine Sicherung:

| Eingriff | Zurücknehmen |
| --- | --- |
| Autologin | `sudo theater/lib/gdm-autologin.sh --file /etc/gdm3/custom.conf --disable` oder `/etc/gdm3/custom.conf.theater-bak` zurückkopieren |
| apt-Sperre | `sudo rm /etc/apt/apt.conf.d/99-theater-no-auto-upgrades` und `sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer` |
| Snap-Sperre | `sudo snap refresh --unhold` |
| Crash-Dialoge | `enabled=1` in `/etc/default/apport`, `sudo systemctl enable --now apport.service` |
| Einschaltknopf | `sudo rm /etc/systemd/logind.conf.d/90-theater-kiosk.conf` |
| Autostart | `rm ~/.config/autostart/org.linuxshowplayer.LinuxShowPlayer.desktop` |
| GNOME-Einstellungen | je Schlüssel `gsettings reset <Schema> <Key>` |

## Das Lekato-Interface im Betrieb

- Das Kabel ist class-compliant. Der Kernel bindet es über `snd-usb-audio` /
  `snd-usbmidi-lib` ohne zusätzlichen Treiber; es gibt nichts zu installieren.
- Die Bezeichnungen IN und OUT am Kabel sind aus Sicht des Interfaces benannt:
  **OUT geht in den MIDI IN des Lightcommanders**. Das ist die häufigste
  Fehlerquelle bei der Verkabelung.
- Im System erscheint das Gerät meist generisch als „USB MIDI Interface“. Sind
  mehrere MIDI-Geräte angeschlossen, den Port vor jeder Produktion mit
  `amidi -l` verifizieren – die `hw:X,Y,Z`-Nummer kann sich nach einem Neustart
  oder beim Umstecken des USB-Ports ändern.
- Diese günstigen Interfaces verwenden meist den QinHeng-CH345-Chip. Note-On,
  Note-Off und Control-Change – also alles, was der Lightcommander für Memories
  braucht – funktionieren zuverlässig; SysEx-Nachrichten sind auf dieser
  Chipklasse unter Linux nicht verlässlich. Für dieses Setup ist das
  unerheblich.
- Linux Show Player läuft als Flatpak und sieht den ALSA-Sequencer nur mit dem
  vom Installer gesetzten Override `flatpak override --user --device=all
  org.linuxshowplayer.LinuxShowPlayer`. Fehlt das MIDI-Gerät in der
  Geräteauswahl, zuerst `flatpak override --user --show <App-ID>` prüfen.

## Nach der Installation

1. Lekato-Interface direkt per USB verbinden und `amidi -l` sowie `aconnect -l`
   ausführen. Das OUT-Kabel in den MIDI IN des Lightcommanders stecken.
2. Audioausgabe mit `aplay -l` und `pactl list short sinks` prüfen und
   links/rechts auf das Tonmischpult legen. In `pavucontrol` Spotify bei
   laufender Wiedergabe auf den vorgesehenen Ausgang umstellen. Bei
   `--with-scarlett`: `alsa-scarlett-gui` starten und Playback 1 auf Line
   Output 1, Playback 2 auf Line Output 2 routen.
3. MIDI-Strecke vor der weiteren Einrichtung einmal isoliert testen:

   ```bash
   ~/Theater/<Projekt>/bin/midi-check.sh --list
   ~/Theater/<Projekt>/bin/midi-check.sh --port hw:1,0,0 --channel 1 --cc 20 --value 127
   ```

4. Linux Show Player mit `flatpak run org.linuxshowplayer.LinuxShowPlayer`
   öffnen, das Lekato-Interface explizit als MIDI-Ausgabe und die gewünschte
   Soundkarte als Audioausgabe auswählen und List Layout mit automatischer
   Auswahl des nächsten Cues konfigurieren.
5. Für jeden Licht-Cue die gewünschte Lightcommander-Memory gezielt per
   MIDI-Control-Change ansteuern. Die Controller-Nummer, der MIDI-Kanal und
   die Werte stammen aus der MIDI-Tabelle des konkreten Lightcommanders.
6. Vor jeder Vorstellung Audio links/rechts, MIDI (`midi-check.sh`), die
   wichtigen Memories, Blackout, Applauslicht und die GO-Taste testen.

Für das Projekt einheitlich WAV mit 48 kHz und 24 Bit verwenden. Den gesamten
Projektordner – inklusive Audiodateien – nach jeder größeren Änderung auf
mindestens einen USB-Stick sichern.

## Quellen

- [Linux Show Player auf Flathub](https://flathub.org/en/apps/org.linuxshowplayer.LinuxShowPlayer)
- [Spotify für Linux](https://www.spotify.com/bf-en/download/linux/)
- [Flatpak-Sandbox-Berechtigungen (`--device`)](https://docs.flatpak.org/en/latest/sandbox-permissions.html)
- [ALSA `amidi` – MIDI-Ports auflisten und Rohdaten senden](https://www.alsa-project.org/alsa-doc/alsa-utils/amidi.html)
- [alsa-scarlett-gui Installationshinweise](https://github.com/geoffreybennett/alsa-scarlett-gui/blob/master/docs/INSTALL.md)
