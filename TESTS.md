# Pruefprotokoll

Stand: 08.09.2026. Getestet unter Linux mit GNU Bash 5.2.37.
Die interaktiven Tests verwenden ein Pseudoterminal ueber Python/pexpect.

## Ergebnisse

35 Prompt-Pruefungen und 22 Installations-/Transferpruefungen bestanden.
Die SSH-Aufrufe wurden lokal simuliert; es wurde kein echter Server kontaktiert.

| Bereich | Geprueft |
| --- | --- |
| Anzeige und Status | Fehler mit Exit-Code und Dauer; schnelle Erfolge ohne Status; Erfolge ab 100 ms; Erhalt von `$?`; vollstaendige Argumente/Anfuehrungszeichen. |
| Zeitmessung | Keine Eingabe-Wartezeit; Befehlslisten, Pipelines, Schleifen und Funktionen; Zeitformatgrenzen; simulierter Komma-Dezimaltrenner; GNU-date- und grober Sekunden-Fallback. |
| Fenstertitel | Setzen vor und nach dem Befehl; Wiederherstellung nach einem vom Programm gesetzten Titel; Abschalten von Titel und Befehlszeile. |
| Sonderfaelle | Ctrl-C waehrend des Befehls; Syntaxfehler; leeres Enter nach Fehlern; `functrace`; erneutes Laden; nicht-interaktives Laden ohne Wirkung; korrekter Status bei reinen Subshells und Funktionsdefinitionen ohne erfundene Laufzeit. |
| Angezeigter Text | Ignorierte History-Befehle werden nicht offengelegt; Text mit `$(...)` wird bei der Prompt-Anzeige nicht erneut ausgefuehrt. |
| Installation | HOME mit Leerzeichen; Erhalt des lokalen Prompts; Sicherung der `.bashrc`; keine doppelte Ladezeile; Sicherung einer selbst bearbeiteten Prompt-Datei beim Update. |
| Simulierter SSH-Transfer | Genau `prompt.sh` und `rc`; Ziel ohne Git im PATH; HOME mit Leerzeichen; unveraenderte Ziel-`.bashrc`; Prompt in der interaktiven Zielshell aktiv; kein Login bei Transferfehler; Weitergabe des Sitzungs-Exit-Codes; Ablehnung ungueltiger Aufrufe. |

Zusaetzlich werden alle ausgelieferten `.sh`-Dateien mit `bash -n` und das
ZIP auf Lesbarkeit und Uebereinstimmung der enthaltenen Dateien geprueft.

## Grenzen der Pruefung

Nicht auf Windows/Git Bash, einem echten SSH-Ziel, Bash 4 oder jedem
Terminalemulator ausgefuehrt. Die Fallbacks wurden unter Bash 5.2 durch
Entfernen von EPOCHREALTIME bzw. Einschraenken des PATH getestet. Der
Komma-Dezimaltrenner wurde durch einen kontrollierten Testwert simuliert.

Nicht jede Bash-Syntaxkombination wird vom DEBUG-basierten Timer vollstaendig
erfasst. Insbesondere reine Subshell-Eingaben sind in README.md als Grenze
beschrieben. Die genaue Darstellung deines lokalen Custom-Themes kann nicht
verglichen werden, weil die Theme-Datei nicht Bestandteil deiner Nachricht war.
