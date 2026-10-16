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
Dokumentationsdateien werden nicht überschrieben; `bin/midi-check.sh` wird bei
jedem Lauf aktualisiert. Ein vorhandener Quellbaum von `alsa-scarlett-gui` wird
unverändert weiterverwendet. Updates dieser Software deshalb bewusst außerhalb
einer laufenden Produktionsserie manuell testen und durchführen.

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

Nach der Spotify-Installation zeigt der Installer die ALSA-Geräte und die
PulseAudio/PipeWire-Ausgänge an. Die vorgesehene Audioausgabe – die Soundkarte
oder, mit `--with-scarlett`, das Scarlett – muss dort als Ausgabegerät
erscheinen.

Es richtet kein automatisches Login ein und schaltet WLAN/Bluetooth nicht ab:
beides sind betriebsspezifische Sicherheits- bzw. Verwaltungsentscheidungen.

Spotify kann mit `spotify` gestartet und anschließend mit einem persönlichen
Spotify-Konto angemeldet werden. Es ist für Pausen- und Hintergrundmusik
geeignet, aber nicht für ausfallsichere Aufführungs-Cues: Streaming,
Kontozugang, Werbung (Free-Konto) und mögliche App-Updates machen es weniger
vorhersehbar als lokal gespeicherte WAV-Dateien in Linux Show Player. Mit
`--skip-spotify` lässt sich die Installation auslassen.

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
