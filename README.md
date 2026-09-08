# SSH-Prompt - angepasst an deine .bashrc

Stand: 08.09.2026

Dieses Paket uebernimmt die Zeitmessung, die Statusregeln und den Fenstertitel
aus deiner bereitgestellten `.bashrc`, ohne `bash-git-prompt` zu benoetigen.
Dein lokaler Prompt bleibt unveraendert. Uebertragen werden weder das
Git-Plugin noch sein Custom-Theme, Windows-Pfade, Java-/Android-/Maven-
Einstellungen oder History-Einstellungen.

Die `.bashrc` aktiviert `GIT_PROMPT_THEME=Custom`, enthaelt aber nicht die
zugehoerige Theme-Datei und keinen vollstaendigen eigenen PS1-Aufbau. Deshalb
ist die SSH-Anzeige funktional daran angepasst, nicht eine exakte optische
Kopie des unbekannten Custom-Themes.

## Dateien

| Datei | Aufgabe |
| --- | --- |
| `prompt.sh` | Angepasster Remote-Prompt, ohne Git-Abhaengigkeit. |
| `ssh-prompt.sh` | Lokale Funktion `sshp`: uebertragen, danach verbinden. |
| `install.sh` | Installation/Update mit Sicherungen. |
| `bashrc.snippet.sh` | Lokale Ladezeile und optionaler SSH-Wrapper. |
| `README.md` | Anleitung und Grenzen. |
| `TESTS.md` | Zusammenfassung der durchgefuehrten Tests. |

Die Startdatei `rc` erzeugt `sshp` automatisch. Sie ist kein separat zu
installierender Bestandteil.

## Installation oder Update in Git Bash

ZIP entpacken, in den enthaltenen Ordner `bash-ssh-prompt` wechseln und dort:

```bash
bash install.sh
source "$HOME/.config/bash/ssh-prompt/ssh-prompt.sh"
sshp alex@server
```

`alex@server` durch dein Ziel oder einen vorhandenen SSH-Config-Alias ersetzen.
Der Installer eignet sich auch zum Aktualisieren der vorherigen Paketversion.
Er installiert unter:

```text
~/.config/bash/ssh-prompt/
    prompt.sh
    ssh-prompt.sh
    bashrc.snippet.sh
```

Die lokale `.bashrc` erhaelt bei Bedarf nur die Ladezeile fuer `ssh-prompt.sh`.
Die Datei `prompt.sh` wird NICHT lokal eingebunden. Vorhandene lokale
Prompt-Bloecke, das Git-Plugin und Umgebungsvariablen werden nicht ersetzt.
Die Snippet-Datei muss nach der Installation nicht zusaetzlich geladen werden.

Sicherungen entstehen vor Aenderungen:

```text
~/.bashrc.ssh-prompt-backup-ZEITSTEMPEL-PROZESSNUMMER
~/.config/bash/ssh-prompt/backups/ZEITSTEMPEL-PROZESSNUMMER/
```

Identische Dateien werden nicht erneut gesichert; dieselbe Ladezeile wird
nicht mehrfach angehaengt. Bereits installierte, selbst veraenderte
Paketdateien werden gesichert und danach durch diese Version ersetzt.

Die bisherige `ssh-prompt.sh`-Uebertragung ist weiterhin kompatibel.
Bei einer vorhandenen Installation ist fuer die neue Darstellung nur die
neue `prompt.sh` erforderlich. Der Installer aktualisiert sie mit Sicherung.
Ein selbst gesetztes `PROMPT_SYNC_FILE` hat weiterhin Vorrang: Es muss auf
die gewuenschte Prompt-Datei zeigen und nicht auf eine alte Version.

## Anzeige auf dem Ziel

Beispiel nach `sleep 1; false` (Dauer und Zeitpunkt sind Beispielwerte):

```text
letzter: sleep 1; false
alex@server: ~/projekt  ✗ 1 · 1.002s
[08.09.2026 14:30:00] $
```

Der Fenstertitel lautet entsprechend:

```text
sleep 1; false — projekt
```

Die Git-Zeile entfaellt ersatzlos. Die zusaetzliche Zeile `letzter:` kann
abgeschaltet werden, waehrend der Befehl im Fenstertitel sichtbar bleibt.

Die Statusregeln entsprechen deinem `prompt_callback()`:

| Ergebnis | Darstellung |
| --- | --- |
| Erfolg unter 100 ms | Kein zusaetzlicher Status. |
| Erfolg ab 100 ms | Gruene Laufzeit, ohne eingeblendete `0`. |
| Fehler | Rotes Fehlersymbol und Exit-Code, dazu die Laufzeit. |
| Fehler vor Befehlsstart | Exit-Code, aber keine erfundene Laufzeit. |

Die Zeitformate entsprechen deiner Funktion: `<1ms`, `42ms`, `1.234s`,
`2m03s` und `1h02m03s`. Farben koennen deaktiviert werden. Benutzer, Host,
Pfad, Datum und Uhrzeit stammen vom Zielsystem. Fuer root zeigt Bash `#`
anstelle von `$`. Datum und Uhrzeit werden beim Zeichnen des Prompts
aktualisiert, nicht als laufende Uhr. [2]

## Anpassungen gegenueber deiner .bashrc

Die Mikrosekundenmessung normalisiert weiterhin Punkt und Komma in
`EPOCHREALTIME`. Auf Bash-Versionen ohne diese Variable wird GNU `date`
versucht; ohne geeignete Ausgabe gibt es eine ausdruecklich als grob
gekennzeichnete Sekundenmessung. [1]

Die Abhaengigkeiten von `setLastCommandState`, `prompt_callback`,
`$Red`, `$Green` und `$ResetColor` aus dem Git-Plugin entfallen. Der
SSH-Prompt setzt seine Farben selbst und uebernimmt den Exit-Code direkt
beim Start seiner `PROMPT_COMMAND`-Funktion. [1]

In deiner `.bashrc` ist `__cmd_timer_arm()` zweimal definiert. Die zweite
Definition entfernt das erneute Setzen des Fenstertitels. Diese Remote-
Version hat genau eine Arm-Funktion und setzt den Titel vor dem Befehl
sowie nach dessen Ende. Deine lokale `.bashrc` wird hierbei NICHT bereinigt.

Ein leeres Enter nach einem Fehler behaelt die letzte Anzeige bei.
Prompt-interne Aktionen werden nicht als Benutzerbefehle gemessen.
Steuerzeichen werden aus angezeigtem Befehls- und Verzeichnistext entfernt.
Dieser Text wird nicht per `eval` oder als ausfuehrbarer PS1-Inhalt eingesetzt.
Bash expandiert PS1; die Datei verwendet deshalb feste Variablenverweise
anstelle eingeklebter Befehlszeilen. [2]

## Einstellungen

Fuer dauerhafte Aenderungen diese Datei LOKAL bearbeiten:

```bash
nano "$HOME/.config/bash/ssh-prompt/prompt.sh"
```

Am Dateianfang stehen:

```bash
: "${SSH_PROMPT_SHOW_COMMAND:=1}"
: "${SSH_PROMPT_COMMAND_MAX:=0}"
: "${SSH_PROMPT_MIN_US:=100000}"
: "${SSH_PROMPT_COLOR:=auto}"
: "${SSH_PROMPT_SET_TITLE:=auto}"
```

| Einstellung | Bedeutung |
| --- | --- |
| `SHOW_COMMAND=0` | Keine zusaetzliche `letzter:`-Zeile. |
| `COMMAND_MAX=0` | Befehl im Prompt nicht kuerzen. Positive Zahl: Zeichenlimit. |
| `MIN_US=100000` | Erfolgs-Laufzeit erst ab 100 ms; `0` zeigt jede Laufzeit. |
| `COLOR=0` | Keine ANSI-Farben. `auto` beachtet `TERM=dumb` und `NO_COLOR`. |
| `SET_TITLE=0` | Keinen Fenstertitel setzen. `auto` nutzt uebliche kompatible TERM-Werte; `1` erzwingt die Ausgabe bei vorhandenem Terminal. |

Beispiel: Nur im Fenstertitel den letzten Befehl zeigen. In `prompt.sh` die
erste Einstellung aendern zu:

```bash
: "${SSH_PROMPT_SHOW_COMMAND:=0}"
```

Im Remote-Terminal kann dieselbe Einstellung sofort geaendert werden:

```bash
SSH_PROMPT_SHOW_COMMAND=0
```

Aenderungen an der lokalen Datei werden beim naechsten `sshp` uebertragen.
Bereits laufende Shells laden sie nicht automatisch neu. Nur lokal gesetzte
Umgebungsvariablen werden vom Paket nicht automatisch ueber SSH weitergegeben.
Bereits auf dem Ziel gesetzte `SSH_PROMPT_*`-Werte haben Vorrang vor den
Standardwerten in der Datei.

## Uebertragung und Server-Konfiguration

Nur diese zwei Dateien werden uebertragen:

```text
~/.cache/ssh-prompt/prompt.sh
~/.cache/ssh-prompt/rc
```

Die automatisch erzeugte `rc` liest zuerst die bestehende Server-`.bashrc`
und danach den angepassten Prompt. Die Server-`.bashrc` wird nicht editiert.
Der Aufruf `bash --rcfile ... -i` startet eine interaktive Nicht-Login-Shell;
`.bash_profile` oder `.profile` werden durch diesen Bash-Aufruf nicht
zusaetzlich gelesen. [3]

In dieser Sitzung ersetzt der Prompt vorhandene `PROMPT_COMMAND`- und
`DEBUG`-Hooks, setzt `PS0`/`PS2` und aktiviert `promptvars`. Andere Prompt-
Frameworks oder an diesen Hooks haengende Funktionen werden nicht parallel
integriert. Sonstige Einstellungen und Aliase aus der Server-`.bashrc`
bleiben bestehen, soweit sie nicht von solchen Hooks abhaengen.

Deine Remote-History-Konfiguration wird nicht ersetzt. Damit beispielsweise
ein vorhandener `history -a`-Prompt-Hook weiterwirkt, muesste er gezielt in
diese Prompt-Funktion integriert werden; das Paket tut dies nicht automatisch.

`sshp` nimmt genau ein Ziel entgegen. Port, Schluessel und Sprungserver
gehoeren in `~/.ssh/config`. Ein normaler Aufruf von `ssh` bleibt unveraendert,
sofern du keinen optionalen Wrapper aus `bashrc.snippet.sh` aktivierst. [4]

Der Helfer verwendet zwei SSH-Aufrufe: einen ohne Terminal fuer den Transfer
und danach einen mit Terminal fuer die Sitzung. Passwort-/MFA-Abfragen
koennen deshalb zweimal erscheinen. SSH-Hostschluesselpruefung und normale
Authentifizierung bleiben aktiv. [4]

## Befehlsanzeige und vertrauliche Argumente

Die Anzeige verwendet den History-Text: die eingegebene Befehlszeile mit
Argumenten und Anfuehrungszeichen, nicht die nach Variablen- oder Alias-
Erweiterung entstandene Argumentliste. Bash kann Eintraege durch
`HISTCONTROL` oder `HISTIGNORE` auslassen. [5]

Falls kein neuer History-Eintrag vorhanden ist, erscheint
`(nicht in der History)` statt einer falschen alten Zeile. Anders als deine
lokale Fallback-Funktion zeigt diese Version ignorierte Befehle nicht ueber
`BASH_COMMAND` doch wieder an. Das gilt auch bei ignorierten Wiederholungen
oder deaktivierter History. Das ist keine Garantie gegen andere Formen
von Protokollierung oder gegen die urspruengliche Anzeige waehrend der Eingabe.

Argumente koennen sowohl in der Prompt-Wiederholung als auch im Fenstertitel
sichtbar sein. Keine Geheimnisse als Kommandozeilenargumente eingeben.
`SHOW_COMMAND=0` deaktiviert nur die Prompt-Wiederholung; fuer den Titel ist
separat `SET_TITLE=0` zu setzen. Das Terminal kann lange Titel selbst kuerzen.

## Voraussetzungen und Grenzen

Lokal: Bash, OpenSSH, tar, gzip, mktemp, cp, rm und cat. Fuer den Installer
werden auch die ueblichen Werkzeuge date, dirname, mkdir, grep und cmp benutzt.
Ziel: Bash 4 oder neuer, tar mit `--no-same-owner` und gzip-Unterstuetzung,
gzip sowie mkdir. Fuer die korrekte Darstellung der Symbole wird ein
UTF-8-faehiges Terminal mit passender Schrift benoetigt. Git ist nicht notwendig.

Die Login-Shell muss die POSIX-Shell-Syntax des Transferbefehls verstehen.
Ziele mit fish/csh als Login-Shell, eingeschraenkten Shells oder erzwungenen
SSH-Kommandos sind durch diesen Helfer nicht abgedeckt.

Die Laufzeit ist eine Anzeige der verstrichenen Zeit, kein Benchmark.
Systemzeitkorrekturen koennen die Messung beeinflussen. Bei Pipelines gilt
der Gesamtstatus von Bash unter den aktiven Shell-Optionen. Hintergrundjobs
werden nur bis zur Rueckkehr ihres Startbefehls gemessen, nicht bis zu ihrem
spaeteren Ende. Reine Subshell-Eingaben wie `(sleep 1)` koennen der Messung
durch den verwendeten DEBUG-Hook entgehen; dafuer sind `time` oder eine
Messung innerhalb der Subshell erforderlich. [1]

Der Ziel-Cache wird pro Benutzer gemeinsam verwendet, nicht als atomare
Versionsablage. Keine unterschiedlichen Prompt-Versionen gleichzeitig auf
denselben Account verteilen. Bei Transferfehlern startet keine neue Sitzung;
eine teilweise geschriebene Cache-Datei kann trotzdem verbleiben.

Alte Git-Dateien aus einer frueheren Einrichtung werden nicht benutzt, aber
auch nicht automatisch geloescht. Eigene Git-Aufrufe in der vorhandenen
Server-`.bashrc` liegen ausserhalb dieses Pakets.

## Entfernen

Die hinzugefuegte Ladezeile und ihren Kommentar aus der lokalen `.bashrc`
entfernen, ebenso einen gegebenenfalls selbst aktivierten SSH-Wrapper.
Danach eine neue lokale Shell oeffnen. Die Paketdateien koennen geloescht
werden, sobald sie nicht mehr benoetigt werden:

```bash
rm -rf -- "$HOME/.config/bash/ssh-prompt"
```

Auf dem Server kann `~/.cache/ssh-prompt` ebenfalls entfernt werden, sobald
keine Sitzung oder andere Einrichtung die Dateien mehr verwendet.

## Pruefung

Siehe `TESTS.md`: interaktive Tests unter Linux/Bash 5.2.37 sowie simulierte
SSH-Uebertragung und Installation. Kein Test auf deinem Windows-Rechner
oder mit deinem echten SSH-Server.

## Technische Referenzen

[1] GNU Bash Reference Manual: Bash Variables und Interactive Shell Behavior.
https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
https://www.gnu.org/software/bash/manual/html_node/Interactive-Shell-Behavior.html

[2] GNU Bash Reference Manual: Controlling the Prompt.
https://www.gnu.org/software/bash/manual/html_node/Controlling-the-Prompt.html

[3] GNU Bash Reference Manual: Bash Startup Files.
https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html

[4] OpenSSH: ssh(1).
https://man.openbsd.org/ssh

[5] GNU Bash Reference Manual: Bash History Facilities.
https://www.gnu.org/software/bash/manual/html_node/Bash-History-Facilities.html
