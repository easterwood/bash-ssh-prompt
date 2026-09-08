# Testbericht

## Zusammenfassung

Die modulare Bash-Konfiguration wurde am 8. September 2026 in einer isolierten
Linux-Testumgebung geprüft. Alle automatisierten Prüfungen waren erfolgreich.

| Bereich | Ergebnis |
|---|---|
| Syntax aller Shell-Dateien | Bestanden |
| Modularer lokaler Loader | Bestanden |
| Lokale `bash-git-prompt`-Anbindung | Bestanden (mit Test-Doppel) |
| Remote-Prompt und `ll` | Bestanden |
| Installation und Sicherung der `.bashrc` | Bestanden |
| Mehrdatei-Synchronisierung | Bestanden (SSH simuliert) |
| Änderungserkennung pro Ziel | Bestanden |
| `known-hosts`-Übersicht und Filter | Bestanden |
| ZIP-Integrität | Bestanden |

## Testumgebung

| Komponente | Version |
|---|---|
| Betriebssystem | Linux, x86-64 |
| Bash | GNU Bash 5.2.21 |
| GNU coreutils (`ls`) | 9.4 |
| AWK | mawk 1.3.4 (2024-01-23) |
| ZIP | Info-ZIP 3.0 |

Git Bash unter Windows und die tatsächlichen Zielserver waren nicht Bestandteil
der ausführbaren Testumgebung.

## Durchgeführte Prüfungen

### 1. Bash-Syntax

Folgende Dateien wurden einzeln mit `bash -n` geprüft:

- `bashrc.sh`
- `prompt.sh`
- `ssh-prompt.sh`
- `.git-prompt-colors.sh`
- `install.sh`
- `bashrc.d/environment.sh`
- `bashrc.d/history.sh`
- `bashrc.d/listing.sh`
- `bashrc.d/ssh-tools.sh`
- `bashrc.d/prompt-core.sh`
- `bashrc.d/prompt-local.sh`

Ergebnis: keine Syntaxfehler.

### 2. Entfernung der Duplikate

Die gemeinsamen Definitionen wurden im gesamten Paket gesucht.

| Definition | Einziger Speicherort |
|---|---|
| `__cmd_timer_now_us` und weitere Timer-Funktionen | `bashrc.d/prompt-core.sh` |
| `ll` | `bashrc.d/listing.sh` |
| `TIME_STYLE` | `bashrc.d/listing.sh` |
| Lokale Git-Prompt-Anbindung | `bashrc.d/prompt-local.sh` |

Der Remote-Prompt lädt `listing.sh` und `prompt-core.sh`, statt deren Inhalt zu
duplizieren.

### 3. Lokale Konfiguration

Ein temporäres Home-Verzeichnis und eine minimale Test-Implementierung von
`bash-git-prompt` wurden erzeugt. Anschließend wurde die installierte `.bashrc`
in einer interaktiven Bash geladen.

Geprüft wurden:

- alle Module werden in der vorgesehenen Reihenfolge geladen;
- `ll`, Timer, `sshp` und der `ssh`-Wrapper sind definiert;
- das Theme `Custom` ist aktiv;
- `.git-prompt-colors.sh` wird aus dem Git-Projekt geladen;
- eine optionale `local.sh` ist nicht erforderlich.

Ergebnis: bestanden.

### 4. Installer

Der Installer wurde mit einer bereits vorhandenen `.bashrc` in einem temporären
Home-Verzeichnis ausgeführt.

Geprüft wurden:

- die bisherige `.bashrc` wird mit Zeitstempel gesichert;
- die neue `.bashrc` enthält nur den Loader auf das Git-Checkout;
- der erzeugte Loader besteht die Syntaxprüfung;
- Pfade werden Shell-sicher geschrieben.

Ergebnis: bestanden.

### 5. Remote-Prompt

`prompt.sh` wurde in einer interaktiven Bash mit simulierten SSH-Variablen
geladen.

Geprüft wurden:

- `prompt-core.sh` und `listing.sh` werden relativ zu `prompt.sh` gefunden;
- der Remote-Prompt-Builder wird installiert;
- die gemeinsame `ll`-Funktion ist verfügbar;
- `ll` kann eine Datei ohne Fehler darstellen;
- der Begrüßungsblock wird durch `SSHP_WELCOME_SHOWN` nicht wiederholt.

Ergebnis: bestanden.

### 6. `ll`-Darstellung

Geprüft wurden:

- Kopfzeile mit Rechte-, Link-, Benutzer-, Größen-, Datums- und Namensspalte;
- keine Gruppenspalte;
- Zeitformat `YYYY-MM-DD HH:MM:SS`;
- menschenlesbare Dateigrößen;
- `root` wird rot dargestellt;
- der aktuelle Benutzer und fremde Benutzer verwenden unterschiedliche Farben.

Ergebnis: bestanden.

### 7. SSH-Synchronisierung

Der ausführbare `ssh`-Client wurde durch ein lokales Test-Doppel ersetzt. Das
Remote-Skript wurde dabei in einem separaten temporären Home-Verzeichnis
ausgeführt.

Geprüft wurden:

- beim ersten Aufruf entstehen eine Synchronisations- und eine Login-Verbindung;
- ohne lokale Änderung entsteht beim zweiten Aufruf nur die Login-Verbindung;
- `prompt.sh`, `listing.sh` und `prompt-core.sh` werden übertragen;
- der Loader wird nur einmal in die Remote-`.bashrc` geschrieben;
- der lokale Synchronisationsstand wird erst nach erfolgreicher Übertragung
  gespeichert.

Beobachtete Verbindungsanzahl: `2`, danach `1`.

Ergebnis: bestanden.

### 8. `ssh`-Wrapper

| Aufruf | Erwarteter Pfad | Ergebnis |
|---|---|---|
| `ssh server` | `sshp server` | Bestanden |
| `ssh -p 2222 server` | natives `ssh` | Bestanden |
| `ssh server uname -a` | natives `ssh` | Bestanden |
| `command ssh server` | natives `ssh` | Bestanden |

### 9. `known-hosts`-Übersicht

Aktualisierung: Die Standardansicht und der Filter starten jetzt keinen
`ssh-keygen`-Prozess mehr. `--fingerprints` startet genau einen Aufruf für die
gesamte Datei und liefert die originale OpenSSH-Ausgabe.

Reproduzierbarer Regressionstest: `bash tests/known-hosts.sh` (bestanden).
Das Test-Doppel zählt Aufrufe und prüft Argumente; synthetische Parserdaten
prüfen Filter, Marker und Hashanzeige. Es ist kein kryptografischer Test und
keine Laufzeitmessung unter Git Bash. Die folgenden Prüfungen beschreiben
zusätzlich den früheren Stand mit echten Testschlüsseln.

Die `known-hosts`-Funktion wurde mit Klartext-, Port-, Marker- und gehashten
Testeinträgen geprüft. Klartextziele können gefiltert werden; gehashte Hostnamen
werden nicht fälschlich als lesbarer Zielname dargestellt. Schlüsseltyp und
SHA256-Fingerabdruck werden aus dem gespeicherten Schlüssel erzeugt.

Ergebnis: bestanden.

### 10. Paketintegrität

Das ZIP-Archiv wurde mit `unzip -t` vollständig geprüft.

Ergebnis: keine beschädigten Einträge.

## Noch manuell zu prüfen

Folgende Prüfungen können nur in der tatsächlichen Umgebung durchgeführt werden:

1. Installation in Git Bash unter Windows.
2. Zusammenspiel mit der real installierten Version von `bash-git-prompt`.
3. Verbindung zu einem tatsächlichen Zielserver über Gateway oder Jump Host.
4. Darstellung der Farben und Unicode-Zeichen im verwendeten Terminal.
5. Verhalten bei kennwortbasierter SSH-Anmeldung.
6. Verfügbarkeit der verwendeten GNU-`ls`-Optionen auf allen Zielservern.

## Manueller Abnahmetest

```bash
bash -n ~/.bashrc
source ~/.bashrc
ll
ssh SERVER
exit
ssh SERVER
```

Beim ersten SSH-Aufruf nach einer lokalen Änderung werden zwei Verbindungen
aufgebaut. Der unmittelbar folgende unveränderte Aufruf benötigt nur eine.
