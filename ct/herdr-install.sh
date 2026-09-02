#!/usr/bin/env bash
# ============================================================================
# In-container installer for the herdr LXC (run as root inside the Debian 12 CT).
# Called by the Proxmox host script via:
#   pct exec <ctid> -- bash /root/herdr-install.sh <HERDR_VERSION> <ROOT_PW>
# Idempotent: safe to re-run.
# ============================================================================
set -euo pipefail

HERDR_VERSION="${1:-${HERDR_VERSION:-0.8.2}}"
ROOT_PW="${2:-}"
WEB_PORT="${WEB_PORT:-7681}"
HERDR_BIN="/usr/local/bin/herdr"
TTYD_BIN="/usr/local/bin/ttyd"
LOG_FILE="/root/herdr-install.log"

# Full debug log, always captured (complete error chains requirement)
exec > >(tee -a "$LOG_FILE") 2>&1

step() { echo "=== $* ==="; }

step "[1/6] apt update + base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget ca-certificates openssh-server \
  iproute2 procps less nano jq

# --- SSH setup: enable root login with password (fresh CT has no root pw) ---
step "[2/6] SSH daemon + root access"
sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
if [[ -n "$ROOT_PW" ]]; then
  echo "root:${ROOT_PW}" | chpasswd
fi
systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd

step "[3/6] herdr binary ${HERDR_VERSION}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  HERDR_ASSET="herdr-linux-x86_64" ;;
  aarch64) HERDR_ASSET="herdr-linux-aarch64" ;;
  *) echo "ERROR: unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac
HERDR_URL="https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${HERDR_ASSET}"
echo "Downloading ${HERDR_URL}"
curl -fL --retry 3 --connect-timeout 15 -o /tmp/herdr "$HERDR_URL" \
  || { echo "ERROR: download failed - check CT internet access + release asset." >&2; exit 2; }
install -m 0755 /tmp/herdr "$HERDR_BIN"
rm -f /tmp/herdr
"$HERDR_BIN" --version || { echo "ERROR: herdr binary failed to execute." >&2; exit 3; }

step "[4/6] ttyd web terminal binary"
case "$ARCH" in
  x86_64)  TTYD_ASSET="ttyd.x86_64" ;;
  aarch64) TTYD_ASSET="ttyd.aarch64" ;;
esac
TTYD_DL=$(curl -fsSL "https://api.github.com/repos/tsl0922/ttyd/releases/latest" \
  | grep -oE "\"browser_download_url\": \"[^\"]+/${TTYD_ASSET}\"" | cut -d'"' -f4 | head -n1)
[[ -n "$TTYD_DL" ]] || { echo "ERROR: could not resolve ttyd asset URL (${TTYD_ASSET})." >&2; exit 4; }
echo "Downloading ${TTYD_DL}"
curl -fL --retry 3 --connect-timeout 15 -o /tmp/ttyd "$TTYD_DL" \
  || { echo "ERROR: ttyd download failed from: ${TTYD_DL}" >&2; exit 4; }
install -m 0755 /tmp/ttyd "$TTYD_BIN"
rm -f /tmp/ttyd
"$TTYD_BIN" --version || { echo "ERROR: ttyd binary failed to execute." >&2; exit 5; }

step "[5/6] systemd units"
cat > /etc/systemd/system/herdr.service <<'EOF'
[Unit]
Description=herdr server (coding agent terminal runtime)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
Environment=TERM=xterm-256color
ExecStart=/usr/local/bin/herdr server
Restart=always
RestartSec=3
ExecStartPost=/bin/sh -c 'for i in $(seq 1 15); do /usr/local/bin/herdr status >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd web terminal for herdr
After=network-online.target herdr.service
Wants=network-online.target
Requires=herdr.service

[Service]
Type=simple
User=root
Environment=HOME=/root
Environment=TERM=xterm-256color
ExecStart=/usr/local/bin/ttyd -W -p ${WEB_PORT} -c herdr:herdr /usr/local/bin/herdr
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable herdr.service ttyd.service
systemctl restart herdr.service
systemctl restart ttyd.service

step "[6/6] self-check"
sleep 3
systemctl is-active herdr.service \
  || { journalctl -u herdr --no-pager -n 50; exit 6; }
systemctl is-active ttyd.service \
  || { journalctl -u ttyd --no-pager -n 50; exit 6; }
"$HERDR_BIN" status >/dev/null 2>&1 \
  || { journalctl -u herdr --no-pager -n 50; exit 7; }
curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${WEB_PORT}/" \
  || { journalctl -u ttyd --no-pager -n 50; exit 8; }

echo "IN-CONTAINER INSTALL OK"
