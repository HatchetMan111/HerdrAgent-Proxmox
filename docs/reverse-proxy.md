# Dashboard & Terminal hinter HTTPS

Das Dashboard und ttyd sprechen HTTP mit Basic-Auth. Für Zugriff aus dem Internet gehören beide hinter einen Reverse Proxy mit TLS — niemals die Ports `8080`/`7681` direkt freigeben.

Empfohlen: **zwei Subdomains**, weil ttyd WebSockets auf Root-Pfaden (`/ws`, `/token`) verwendet.

- `herdr.example.com` → `CT-IP:8080` (Dashboard)
- `term.example.com` → `CT-IP:7681` (Web-Terminal)

---

## Caddy

Caddy holt automatisch Let's-Encrypt-Zertifikate und unterstützt WebSockets ohne Extra-Konfiguration.

```caddyfile
herdr.example.com {
    encode zstd gzip
    reverse_proxy 10.0.0.50:8080
}

term.example.com {
    encode zstd gzip
    reverse_proxy 10.0.0.50:7681
}
```

`10.0.0.50` durch die CT-IP ersetzen. Danach:

```bash
systemctl reload caddy
```

Caddy setzt `X-Forwarded-Proto` automatisch; der „Terminal öffnen"-Link im Dashboard bleibt dadurch korrekt.

---

## nginx

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name herdr.example.com;

    ssl_certificate     /etc/letsencrypt/live/herdr.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/herdr.example.com/privkey.pem;

    location / {
        proxy_pass http://10.0.0.50:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }
}

server {
    listen 443 ssl http2;
    server_name term.example.com;

    ssl_certificate     /etc/letsencrypt/live/term.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/term.example.com/privkey.pem;

    location / {
        proxy_pass http://10.0.0.50:7681;
        proxy_http_version 1.1;

        # ttyd braucht WebSockets und lange offene Verbindungen
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host       $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;

        proxy_read_timeout  7d;
        proxy_send_timeout  7d;
        proxy_buffering     off;
    }
}
```

```bash
nginx -t && systemctl reload nginx
```

---

## Basic-Auth bleibt aktiv

Der Proxy reicht den `Authorization`-Header durch. Dashboard und ttyd prüfen weiterhin selbst die Zugangsdaten aus `/etc/default/herdr-web`.

Optional kann der Proxy zusätzlich eine eigene Auth-Schicht erzwingen (z. B. `basicauth` in Caddy oder `auth_basic` in nginx). Dann müssen die Zugangsdaten zweimal eingegeben werden — oder man deaktiviert die interne Auth bewusst **nicht**, sondern nutzt nur eine der beiden Ebenen.

> Das Dashboard hat bewusst keine eigene Benutzerverwaltung. Für Mehrbenutzerbetrieb: getrennte Container oder einen vorgelagerten Identity-Aware-Proxy (z. B. Authentik, Pocket ID) verwenden.

---

## Alternative: ein Host, Pfad `/terminal`

ttyd kann unter einem Unterpfad laufen. Dafür im Container die Unit anpassen:

```bash
pct exec CT-ID -- sed -i 's#/usr/local/bin/ttyd -W#/usr/local/bin/ttyd -W -b /terminal#' \
  /etc/systemd/system/ttyd.service
pct exec CT-ID -- systemctl daemon-reload && pct exec CT-ID -- systemctl restart ttyd
```

Dann im Proxy `term.example.com` durch `herdr.example.com/terminal` ersetzen. Achtung: Der Terminal-Button im Dashboard zeigt weiterhin auf `CT-IP:7681`; für diesen Betrieb den Link im Dashboard-Header manuell anpassen oder die Subdomain-Variante bevorzugen.

---

## Firewall

Auf dem Proxmox-Host die Container-Ports nur für den Proxy erreichbar machen, z. B. mit der Proxmox-Firewall:

```bash
# Dashboard und Terminal nur aus dem Proxy-/LAN-Netz
pct set CT-ID --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=1
```

Regeln im PVE-Firewall-UI (Datacenter → Firewall bzw. CT → Firewall):

| Richtung | Protokoll | Port | Quelle |
| --- | --- | --- | --- |
| IN | TCP | 8080 | Proxy-IP / LAN |
| IN | TCP | 7681 | Proxy-IP / LAN |
| IN | TCP | 22 | Admin-Netz |

Für öffentlichen Betrieb zusätzlich `fail2ban` oder Rate-Limiting am Proxy aktivieren.
