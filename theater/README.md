# Theater-PC auf Ubuntu 24.04

Dieses Verzeichnis enthält eine reproduzierbare Grundinstallation für einen
Theater-PC mit Linux Show Player, Spotify, Focusrite Scarlett 18i20 der ersten
Generation und einem per MIDI angesteuerten MA Lightcommander 12/2.

Der Rechner erzeugt **kein DMX**. Das Scarlett überträgt Audio und MIDI; der
Lightcommander speichert die Licht-Memories und steuert die DMX-Anlage selbst.

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

Ein erneuter Aufruf ist grundsätzlich möglich. Bereits vorhandene Show- und
Dokumentationsdateien werden nicht überschrieben. Ein vorhandener Quellbaum
von `alsa-scarlett-gui` wird ebenfalls unverändert weiterverwendet. Updates
dieser Software deshalb bewusst außerhalb einer laufenden Produktionsserie
manuell testen und durchführen.

## Was das Skript einrichtet

- Ubuntu-Tools: Flatpak, Snap, ALSA-Werkzeuge, pavucontrol und Build-Abhängigkeiten
- Linux Show Player (`org.linuxshowplayer.LinuxShowPlayer`) über Flathub
- Spotify als offizielles Snap-Paket
- `alsa-scarlett-gui` aus dem offiziellen Quellrepository
- Projektbaum `~/Theater/<Projekt>/{Show,Audio,Dokumentation,Backup}`
- GNOME-Einstellungen gegen Bildschirm-Leerlauf, Suspend und
  Benachrichtigungsbanner

Es richtet kein automatisches Login ein und schaltet WLAN/Bluetooth nicht ab:
beides sind betriebsspezifische Sicherheits- bzw. Verwaltungsentscheidungen.

Spotify kann mit `spotify` gestartet und anschließend mit einem persönlichen
Spotify-Konto angemeldet werden. Es ist für Pausen- und Hintergrundmusik
geeignet, aber nicht für ausfallsichere Aufführungs-Cues: Streaming,
Kontozugang, Werbung (Free-Konto) und mögliche App-Updates machen es weniger
vorhersehbar als lokal gespeicherte WAV-Dateien in Linux Show Player. Mit
`--skip-spotify` lässt sich die Installation auslassen.

## Nach der Installation

1. Scarlett 18i20 direkt per USB verbinden und `aplay -l` sowie `aconnect -l`
   ausführen.
2. `alsa-scarlett-gui` starten, dann Playback 1 auf Line Output 1 und Playback
   2 auf Line Output 2 routen.
3. Scarlett Line Out 1/2 mit dem Tonmischpult verbinden, Scarlett MIDI OUT mit
   MA Lightcommander MIDI IN.
4. Linux Show Player mit `flatpak run org.linuxshowplayer.LinuxShowPlayer`
   öffnen, das Scarlett explizit als Audio- und MIDI-Ausgabe auswählen und
   List Layout mit automatischer Auswahl des nächsten Cues konfigurieren.
5. Für jeden Licht-Cue die gewünschte Lightcommander-Memory gezielt per
   MIDI-Control-Change ansteuern. Die Controller-Nummer, der MIDI-Kanal und
   die Werte stammen aus der MIDI-Tabelle des konkreten Lightcommanders.
6. Vor jeder Vorstellung Audio links/rechts, MIDI, die wichtigen Memories,
   Blackout, Applauslicht und die GO-Taste testen.

Für das Projekt einheitlich WAV mit 48 kHz und 24 Bit verwenden. Den gesamten
Projektordner – inklusive Audiodateien – nach jeder größeren Änderung auf
mindestens einen USB-Stick sichern.

## Quellen

- [Linux Show Player auf Flathub](https://flathub.org/en/apps/org.linuxshowplayer.LinuxShowPlayer)
- [Spotify für Linux](https://www.spotify.com/bf-en/download/linux/)
- [alsa-scarlett-gui Installationshinweise](https://github.com/geoffreybennett/alsa-scarlett-gui/blob/master/docs/INSTALL.md)
