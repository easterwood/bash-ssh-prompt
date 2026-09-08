# Modulare Bash-Konfiguration

Die echte `~/.bashrc` enthält nach der Installation nur noch einen Loader. Alle
persönlichen Einstellungen liegen in diesem Git-Projekt.

## Module

- `bashrc.d/environment.sh`: Java, JMeter, Android und Maven
- `bashrc.d/history.sh`: Bash-History
- `bashrc.d/listing.sh`: gemeinsame `ll`-Darstellung
- `bashrc.d/prompt-core.sh`: gemeinsame Zeitmessung und Fenstertitel
- `bashrc.d/prompt-local.sh`: lokale Anbindung an `bash-git-prompt`
- `prompt.sh`: Remote-Darstellung; lädt die gemeinsamen Module
- `ssh-prompt.sh`: Synchronisierung und `ssh`-Wrapper
- `.git-prompt-colors.sh`: lokales Custom-Theme

## Installation

Im Git-Projekt ausführen:

```bash
bash install.sh
source ~/.bashrc
```

Die bisherige `.bashrc` wird mit Zeitstempel gesichert. `install.sh` ersetzt sie
anschließend durch einen dreizeiligen Loader auf dieses Checkout.

`sshp` synchronisiert `prompt.sh`, `bashrc.d/listing.sh` und
`bashrc.d/prompt-core.sh`. Ohne lokale Änderungen öffnet `ssh HOST` weiterhin
sofort die einzelne interaktive Verbindung.
