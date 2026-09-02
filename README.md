# herdr-proxmox

> [herdr](https://github.com/herdrdev/herdr) — "the runtime your coding agents live on" —
> als **LXC-Container** auf **Proxmox VE** per Einzeiler, im Stil der
> [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Der Container läuft:

- **herdr-Server** (`herdr server`, headless) als systemd-Service — Agents/Panes
  überleben Reboots, Sessions werden wiederhergestellt
- **ttyd Web-Terminal** auf Port **7681** als systemd-Service — volle herdr-TUI
  im Browser (Basic-Auth `herdr:herdr`, bitte ändern!)
- **SSH** — klassischer tmux-Style-Zugang: `ssh root@CT-IP`, dort `herdr`

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main/install/herdr.sh)"
```

> Der Einzeiler lädt das Install-Script direkt aus diesem Repo (`main`-Branch).

### Was das Script macht

1. Prüft Proxmox-Host + Root + Internet, legt einen Debug-Log unter
   `/tmp/herdr-proxmox-debug/` an (immer, entspricht dem `bash -x`-Log-Wunsch)
2. Fragt CT-ID, vCPU (2), RAM (2048 MiB), Disk (8 GiB) ab — Defaults in Klammern
3. Erstellt einen **unprivilegierten** Debian-12-LXC (`nesting=1`, `onboot: 1`, DHCP)
4. Installiert im Container per `pct exec`:
   - herdr-Binary v0.8.2 (x86_64/aarch64) nach `/usr/local/bin/herdr`
   - ttyd (offizieller GitHub-Release) nach `/usr/local/bin/ttyd`
   - systemd-Units `herdr.service` + `ttyd.service` (`Restart=always`,
     `After=network-online.target`, enabled)
5. Verifiziert automatisch:
   - `systemctl is-active herdr ttyd`
   - herdr-Status-Check (`herdr status`)
   - HTTP-Check auf `http://[CT-IP]:7681`
   - SSH-Daemon aktiv
6. Gibt finale URL + IPs + Debug-Log-Pfad aus

Bei jedem Fehler wird die **komplette Fehlerkette** ausgegeben:
Journal-Tail (`journalctl -u <service> -n 50/80`), Exit-Codes, vollständiges
Install-Log — nie nur die letzte Zeile. Re-Run mit `bash -x` wird empfohlen.

## Zugriff

| Weg | Adresse | Auth |
|---|---|---|
| Browser (Web-Terminal) | `http://[CT-IP]:7681` | Basic-Auth: **zufälliges Passwort** — wird am Ende der Installation groß ausgegeben |
| SSH (empfohlen) | `ssh root@[CT-IP]` → `herdr` | SSH-Key (wird injiziert) oder Root-Passwort (wird ausgegeben) |
| Proxmox | `pct enter <CT-ID>` → `herdr` | — |

Die Zugangsdaten (Web-Benutzer/Passwort, ggf. Root-Passwort) werden am Ende
der Installation im Block **"ANMELDUNG / LOGIN"** angezeigt.

Web-Credentials ändern (liegen root-only in `/etc/default/ttyd-herdr`):

```bash
pct exec <CT-ID> -- bash -c 'read -p "user:pass: " C && sed -i "s/^WEB_PW=.*/WEB_PW=${C#*:}/; s/^WEB_USER=.*/WEB_USER=${C%%:*}/" /etc/default/ttyd-herdr && systemctl restart ttyd'
```

> Hinweis: Das alte Default-Passwort `herdr:herdr` gibt es nicht mehr — jede
> Installation bekommt ein zufälliges Passwort.

## Update

```bash
pct exec <CT-ID> -- herdr update
```

Oder den kompletten Install-Prozess erneut laufen lassen (idempotent):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main/install/herdr.sh)"
# gleiche CT-ID eingeben → Installation im Container wird aktualisiert
```

## Deinstallation

```bash
pct stop <CT-ID> && pct destroy <CT-ID> --purge
```

## Reboot-Test (Beleg, dass alles reboot-sicher ist)

```bash
pct reboot <CT-ID>
sleep 25
pct exec <CT-ID> -- systemctl is-active herdr ttyd     # → active / active
pct exec <CT-ID> -- herdr status                      # → server running
curl -s -o /dev/null -w '%{http_code}\n' http://[CT-IP]:7681/  # → 200
```

Erwartete Ausgabe:

```
active
active
server running
200
```

## Troubleshooting

- **Debug-Logs:** `/tmp/herdr-proxmox-debug/` (Host) und `/root/herdr-install.log` (im CT)
- **Service-Logs:** `pct exec <CT-ID> -- journalctl -u herdr -u ttyd -n 100 --no-pager`
- **Kompletter Trace:** Einzeiler lokal klonen und `bash -x install/herdr.sh` ausführen
- **Kein DHCP im LXC:** Bridge `vmbr0` prüfen oder im Script `ip=dhcp` auf statisch ändern

## Hinweise

- herdr selbst nutzt einen **Unix-Socket** (`~/.config/herdr/herdr.sock`) — kein TCP-Port, kein Cloud-Dienst. Alles läuft lokal im Container.
- Web-Terminal (ttyd) ist ein Komfort-Zugang; für ernsthafte Agent-Arbeit ist SSH der bessere Weg (Mouse-Support, stabile Tastatur).
- getestet mit herdr v0.8.2; neuere Version: `HERDR_VERSION=x.y.z` beim Einzeiler mitgeben (Umgebungsvariable).
