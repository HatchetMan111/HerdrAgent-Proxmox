# herdr-proxmox

> [herdr](https://github.com/herdrdev/herdr) — „the runtime your coding agents live on" — als **LXC-Container** auf **Proxmox VE**, inklusive **Web-Dashboard**, Web-Terminal und SSH. Im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Ein Einzeiler erzeugt einen unprivilegierten Debian-12-Container mit:

| Dienst | Port | Zweck |
| --- | --- | --- |
| **herdr server** | Unix-Socket | Agents/Panes laufen headless weiter, Sessions werden nach einem Reboot wiederhergestellt |
| **Web-Dashboard** | `8080` | Agents, Workspaces, Panes, Status, Systemwerte und Pane-Ausgabe im Browser |
| **Web-Terminal (ttyd)** | `7681` | die volle herdr-TUI im Browser |
| **SSH** | `22` | klassischer Zugang: `ssh root@CT-IP`, dort `herdr` |

Dashboard und Terminal teilen sich einen Benutzer und ein zufällig erzeugtes Passwort. Beide sind per HTTP-Basic-Auth geschützt.

---

## Dashboard

Das Dashboard ist eine dependency-freie Python-Anwendung (nur Standardbibliothek) und spricht direkt mit der lokalen **herdr-Socket-API**. Es zeigt live:

- **Agents** mit Status `arbeitet`, `wartet`, `fertig`, `bereit`
- **Workspaces → Tabs → Panes** als Baum, inklusive Fokus und Agent-Zuordnung
- **Pane-Ausgabe** im Drawer (`visible`, `recent`, `recent-unwrapped`, `detection`), mit Auto-Refresh und Kopieren
- **Prompt senden** an einen Agent (`agent.prompt`, bei Shells automatischer Fallback auf Text + Enter)
- **Systemwerte** des Containers: Load, RAM, Disk, Uptime
- **systemd-Status** von `herdr`, `ttyd` und `herdr-dashboard`
- Schnellaktionen: neues Terminal, neuer Tab, Pane fokussieren
- **Drag & Drop**: Pane per Drag & Drop auf ein anderes Pane im selben Tab ziehen → Sortierung via `pane.swap`

Alles läuft lokal im Container. Es gibt keinen Cloud-Dienst und keinen zusätzlichen TCP-Port für herdr selbst.

### Warum nicht herdr-app im Container?

[herdr-app](https://github.com/herdrdev/herdr-app) ist die **native Desktop-App** (GPUI/Vulkan) und braucht eine grafische Sitzung. Sie lässt sich nicht sinnvoll headless in einem LXC als Web-Oberfläche starten. Deshalb gibt es hier zwei Wege:

1. **Im Browser:** das mitgelieferte Dashboard (`http://CT-IP:8080`).
2. **Desktop-App lokal:** herdr-app auf dem eigenen Rechner installieren und den Container als SSH-Maschine hinzufügen:

```bash
# lokal (Linux/macOS)
curl -fsSL https://releases.herdr.dev/app/install.sh | sh
```

Danach in der App: **Settings → Machines → Add machine** → `root@CT-IP`. Die Spaces, Tabs und Agents des Servers erscheinen in der App; die Terminals laufen weiter im Container.

---

## Installation

Auf dem **Proxmox-Host als root**:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main/install/herdr.sh)"
```

### Optionen

Das Script fragt CT-ID, vCPU, RAM und Disk interaktiv ab. Für unbeaufsichtigte Installationen lassen sich die Werte als Umgebungsvariablen setzen:

| Variable | Default | Bedeutung |
| --- | --- | --- |
| `CT_ID` | nächste freie ID | Container-ID |
| `CT_CORES` | `2` | vCPUs |
| `CT_RAM` | `2048` | RAM in MiB |
| `CT_DISK` | `8` | Disk in GiB |
| `CT_DISK_STORE` | `local-lvm` | Proxmox-Storage für das Rootfs |
| `HERDR_VERSION` | `0.9.5` | herdr-Release-Tag (ohne `v`) oder `latest` |
| `WEB_PORT` | `7681` | ttyd-Port |
| `DASH_PORT` | `8080` | Dashboard-Port |
| `TRACE` | `0` | `1` aktiviert `bash -x` |
| `OPENROUTER_KEY` | *(leer)* | optionaler OpenRouter API-Key für Agenten (siehe [Agenten & OpenRouter](#agenten--openrouter)) |

Beispiel:

```bash
CT_ID=120 CT_CORES=4 CT_RAM=4096 HERDR_VERSION=latest \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main/install/herdr.sh)"
```

### Was das Script macht

1. Prüft Proxmox-Host, Root-Rechte und Internet; legt einen Debug-Log unter `/tmp/herdr-proxmox-debug/` an.
2. Lädt bei Bedarf das Debian-12-Template und erstellt einen **unprivilegierten** LXC (`nesting=1`, `onboot: 1`, DHCP).
3. Installiert im Container:
   - herdr-Binary (x86_64/aarch64) nach `/usr/local/bin/herdr`
   - ttyd (gepinnt, mit API-Fallback) nach `/usr/local/bin/ttyd`
   - Python 3, git, ripgrep und Basis-Tools
   - Dashboard nach `/opt/herdr-dashboard`
   - systemd-Units `herdr.service`, `ttyd.service`, `herdr-dashboard.service`
4. Verifiziert automatisch:
   - `systemctl is-active herdr ttyd herdr-dashboard`
   - `herdr status`
   - HTTP + Basic-Auth für Terminal **und** Dashboard
   - `/api/snapshot` des Dashboards (echte herdr-Daten)
   - SSH-Daemon
5. Gibt die komplette Login-Box aus und schreibt alle Schritte in ein Log.

Bei Fehlern wird die komplette Kette ausgegeben: Journal-Tail der betroffenen Unit, Exit-Codes und das vollständige Install-Log. Ein Re-Run ist idempotent.

---

## Zugriff

| Weg | Adresse | Auth |
| --- | --- | --- |
| **Dashboard** | `http://CT-IP:8080` | Basic-Auth (Benutzer/Passwort aus der Installations-Box) |
| **Web-Terminal** | `http://CT-IP:7681` | gleiches Basic-Auth |
| **SSH** | `ssh root@CT-IP` → `herdr` | injizierter SSH-Key oder Root-Passwort |
| **Proxmox** | `pct enter CT-ID` → `herdr` | — |

Die Zugangsdaten stehen am Ende der Installation im Block **„ANMELDUNG / LOGIN"**. Sie liegen root-only in `/etc/default/herdr-web`.

### Passwort ändern

```bash
pct exec CT-ID -- bash -c '
  read -p "user:pw: " C &&
  sed -i "s/^WEB_PW=.*/WEB_PW=${C#*:}/; s/^WEB_USER=.*/WEB_USER=${C%%:*}/" /etc/default/herdr-web &&
  systemctl restart ttyd herdr-dashboard'
```

### Hinter HTTPS / Reverse Proxy

Für Zugriff von außen bitte nicht die Ports direkt ins Internet stellen. Beispiele für Caddy und nginx (inkl. WebSocket für ttyd) stehen in [docs/reverse-proxy.md](docs/reverse-proxy.md).

---

## Agenten & OpenRouter

Headless im Container laufende Agents brauchen einen LLM-API-Key. Der Installer unterstützt das optional über **OpenRouter**.

### Einmalig beim Install (interaktiv)

Beim ersten Lauf des Installations-Scripts wird (bei interaktiver Ausführung) optional gefragt:

```
OpenRouter API-Key (optional, fuer Agenten via OpenRouter):
```

Der Key wird im Container unter `/etc/default/herdr-web` (`OPENROUTER_API_KEY=…`) gespeichert und über die systemd-Unit `herdr.service` (`EnvironmentFile=/etc/default/herdr-web`) an den Server weitergegeben. Alle neu gestarteten Agenten/Panes erhalten damit automatisch:

```
ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1
ANTHROPIC_API_KEY=<dein-Key>
```

(optional über `OPENROUTER_MODEL` auch `ANTHROPIC_MODEL`).

### Über das Dashboard (optional, pro Workspace)

Beim Anlegen eines Workspaces über das Dashboard (`Neues Terminal`) kann optional ein **OpenRouter API-Key** eingetragen werden. Dieser wird beim Anlegen an den Server übergeben (`workspace.create` → `env`) und wirkt sich auf den frischen Workspace/Pane aus.

Fehlt der Key im Dashboard, nutzt der Server den im Install-Script hinterlegten Key.

### CLI (einzelner Agent / Split)

Alternativ über die herdr-CLI mit `--env KEY=VALUE` (wiederholbar):

```bash
pct exec CT-ID -- herdr tab create --env ANTHROPIC_API_KEY=<key> --env ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1
```

oder für einen neuen Pane in einem bestehenden Workspace:

```bash
pct exec CT-ID -- herdr pane split --env ANTHROPIC_API_KEY=<key>
```

---

## Update

Nur den herdr-Server aktualisieren:

```bash
pct exec CT-ID -- herdr update
```

Kompletten Stack aktualisieren (empfohlen, idempotent):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main/install/herdr.sh)"
# gleiche CT-ID eingeben
```

Dabei werden herdr, ttyd, Dashboard-Dateien und systemd-Units aktualisiert. Vorhandene Zugangsdaten bleiben erhalten; Ports lassen sich über `WEB_PORT`/`DASH_PORT` ändern.

---

## Reboot-Test

```bash
pct reboot CT-ID
sleep 25
pct exec CT-ID -- systemctl is-active herdr ttyd herdr-dashboard
pct exec CT-ID -- herdr status
curl -s -o /dev/null -w '%{http_code}\n' -u 'USER:PASS' http://CT-IP:8080/
curl -s -o /dev/null -w '%{http_code}\n' -u 'USER:PASS' http://CT-IP:7681/
```

Erwartet:

```
active
active
active
server running
200
200
```

---

## Deinstallation

```bash
pct stop CT-ID && pct destroy CT-ID --purge
```

---

## Troubleshooting

```bash
# Status aller Dienste
pct exec CT-ID -- systemctl status herdr ttyd herdr-dashboard --no-pager

# Logs
pct exec CT-ID -- journalctl -u herdr -u ttyd -u herdr-dashboard -n 150 --no-pager

# Dashboard-Dateien und Credentials
pct exec CT-ID -- ls -la /opt/herdr-dashboard /etc/default/herdr-web

# herdr-Socket prüfen
pct exec CT-ID -- herdr status
pct exec CT-ID -- ls -la /root/.config/herdr/

# Kompletter Trace (lokal geklont)
bash -x install/herdr.sh
```

Weitere Debug-Artefakte:

- Host: `/tmp/herdr-proxmox-debug/`
- Container: `/root/herdr-install.log`

Häufige Ursachen:

- **Kein DHCP im LXC:** Bridge `vmbr0` prüfen oder im Script `ip=dhcp` auf eine statische Konfiguration ändern.
- **Dashboard zeigt „offline":** `herdr` läuft nicht oder der Socket liegt nicht unter `/root/.config/herdr/herdr.sock`. Mit `pct exec CT-ID -- herdr status` prüfen.
- **Port belegt:** `DASH_PORT`/`WEB_PORT` beim Installer setzen.
- **Login klappt nicht:** Browser cached Basic-Auth; `http://CT-IP:8080/logout` aufrufen oder privates Fenster nutzen.

---

## Sicherheit

- herdr selbst lauscht **nur auf einem Unix-Socket** im Container, nicht auf TCP.
- ttyd und Dashboard sind mit **Basic-Auth** geschützt; das Passwort wird pro Installation zufällig erzeugt.
- Das Dashboard kann nur eine **whitelisted Menge** an Socket-Methoden aufrufen; es leitet keine beliebigen Methoden weiter.
- Credentials liegen in einer root-only Datei (`0600`), nicht in world-readable Unit-Dateien.
- Für öffentlichen Zugriff: Reverse Proxy mit TLS, VPN oder Proxmox-Firewall verwenden. Siehe [docs/reverse-proxy.md](docs/reverse-proxy.md).
- Das Dashboard hat bewusst **keine** Authentifizierung über Dritte, keine Telemetrie und keine externen Assets.

---

## Repository

```
install/herdr.sh          # Host-Installer (Proxmox)
ct/herdr-install.sh       # In-Container-Installer
dashboard/server.py       # Dashboard-Backend (Python-Stdlib, Socket-API)
dashboard/static/         # Dashboard-UI (HTML/CSS/JS, ohne Build-Schritt)
docs/reverse-proxy.md     # Caddy/nginx-Beispiele
.github/workflows/ci.yml  # shellcheck, Python- und JS-Syntaxcheck
```

### Entwicklung

```bash
bash -n install/herdr.sh ct/herdr-install.sh
shellcheck install/herdr.sh ct/herdr-install.sh
python3 -m py_compile dashboard/server.py
node --check dashboard/static/app.js
```

Das Dashboard lässt sich lokal gegen einen laufenden herdr-Server testen:

```bash
WEB_USER=herdr WEB_PW=test DASH_PORT=8080 HERDR_SOCKET_PATH=/root/.config/herdr/herdr.sock \
  python3 dashboard/server.py
```

---

## Hinweise

- Getestet mit herdr v0.9.5 und ttyd v1.7.7 (Debian 12, x86_64). Ältere herdr-Versionen können eine andere Socket-API haben.
- Das Web-Terminal ist ein Komfort-Zugang; für ernsthafte Agent-Arbeit ist SSH oder die Desktop-App die bessere Wahl.
- herdr nutzt intern weiterhin seinen Unix-Socket; das Dashboard ist ein Client davon.
