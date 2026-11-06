#!/usr/bin/env bash
# ============================================================================
# In-container installer for the herdr LXC (run as root inside the Debian 12 CT).
#
# Called by the Proxmox host script via:
#   pct exec <ctid> -- bash /root/herdr-install.sh \
#       <HERDR_VERSION> <ROOT_PW> <WEB_USER> <WEB_PW> <DASH_PORT> <RAW_REPO_BASE> <WEB_PORT> \
#       <OPENROUTER_API_KEY> <OPENROUTER_MODEL> <HERDR_PLUGINS>
#
# <OPENROUTER_API_KEY>  optional OpenRouter API-Key
# <OPENROUTER_MODEL>    optional OpenRouter model (ANTHROPIC_MODEL), leer = OpenRouter default
# <HERDR_PLUGINS>        space-separated GitHub sources owner/repo[/subdir][@ref] for community plugins
#                        (optional @ref pin, z.B. "aemrebarut/herdr-dagr@v0.3.1")
#
# Idempotent: safe to re-run. Existing config, credentials and services are
# updated in place.
# ============================================================================
set -euo pipefail

HERDR_VERSION="${1:-${HERDR_VERSION:-0.9.5}}"
ROOT_PW="${2:-}"
WEB_USER="${3:-herdr}"
WEB_PW="${4:-}"
DASH_PORT="${5:-8080}"
RAW_REPO_BASE="${6:-https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main}"
# Positional 7 keeps backward compatibility with older host scripts.
WEB_PORT="${7:-${WEB_PORT:-7681}}"
OPENROUTER_API_KEY="${8:-${OPENROUTER_API_KEY:-}}"
OPENROUTER_MODEL="${9:-${OPENROUTER_MODEL:-}}"
HERDR_PLUGINS="${10:-${HERDR_PLUGINS:-aemrebarut/herdr-dagr@v0.3.1 devswha/ovis}}"
HERDR_BIN="/usr/local/bin/herdr"
TTYD_BIN="/usr/local/bin/ttyd"
DASH_DIR="/opt/herdr-dashboard"
LOG_FILE="/root/herdr-install.log"

# Random web password when none provided
# NOTE: dd instead of `tr | head` (head would SIGPIPE-fail under pipefail)
if [[ -z "$WEB_PW" ]]; then
  # 256 bytes -> ~62 alnum chars survive tr; ${WEB_PW:0:16} is then always 16 chars
  WEB_PW="$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'a-zA-Z0-9' || true)"
  [[ -z "$WEB_PW" ]] && WEB_PW="herdr$(date +%s)"
  WEB_PW="${WEB_PW:0:16}"
fi

for v in "$DASH_PORT" "$WEB_PORT"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid port: '$v'" >&2; exit 1; }
done

# Full debug log, always captured (complete error chains requirement)
exec > >(tee -a "$LOG_FILE") 2>&1

step() { echo "=== $* ==="; }
fail() {
  echo "ERROR: $*" >&2
  exit 1
}

step "[1/10] apt update + base packages"
export DEBIAN_FRONTEND=noninteractive

# DNS readiness check (fresh CTs can have transient DNS failures right after DHCP)
DNS_OK=0
for i in $(seq 1 10); do
  if getent hosts deb.debian.org >/dev/null 2>&1 || getent hosts github.com >/dev/null 2>&1; then
    DNS_OK=1; break
  fi
  echo "DNS not ready yet (attempt ${i}/10) - waiting 3s..."
  sleep 3
done
[[ "$DNS_OK" == "1" ]] \
  || { echo "ERROR: DNS resolution failed after 10 attempts - check CT network (bridge/DHCP/DNS)." >&2; exit 9; }

apt-get update -qq
apt-get install -y -qq curl wget ca-certificates openssh-server \
  python3 git ripgrep iproute2 procps less nano jq unzip

# --- SSH setup: enable root login with password (fresh CT has no root pw) ---
step "[2/10] SSH daemon + root access"
sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
if [[ -n "$ROOT_PW" ]]; then
  echo "root:${ROOT_PW}" | chpasswd
fi
systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd

step "[3/10] herdr binary ${HERDR_VERSION}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  HERDR_ASSET="herdr-linux-x86_64" ;;
  aarch64) HERDR_ASSET="herdr-linux-aarch64" ;;
  *) fail "unsupported architecture: ${ARCH}" ;;
esac
HERDR_URL="https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${HERDR_ASSET}"
echo "Downloading ${HERDR_URL}"
curl -fL --retry 5 --retry-all-errors --connect-timeout 15 -o /tmp/herdr "$HERDR_URL" \
  || fail "download failed - check CT internet access + release asset (${HERDR_URL})"
install -m 0755 /tmp/herdr "$HERDR_BIN"
rm -f /tmp/herdr
"$HERDR_BIN" --version || fail "herdr binary failed to execute."

step "[4/10] ttyd web terminal binary"
# Pinned version + direct URL (no GitHub API call needed - API has rate limits
# and adds a DNS dependency that can fail transiently on fresh CTs)
TTYD_VERSION="1.7.7"
case "$ARCH" in
  x86_64)  TTYD_ASSET="ttyd.x86_64" ;;
  aarch64) TTYD_ASSET="ttyd.aarch64" ;;
esac
TTYD_DL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${TTYD_ASSET}"

# Fallback: resolve latest via API only if the pinned direct download fails
if ! curl -fL --retry 5 --retry-all-errors --connect-timeout 15 -o /tmp/ttyd "$TTYD_DL"; then
  echo "Pinned download failed - trying GitHub API fallback..."
  TTYD_DL=$(curl -fsSL --retry 5 --retry-all-errors "https://api.github.com/repos/tsl0922/ttyd/releases/latest" \
    | grep -oE "\"browser_download_url\": \"[^\"]+/${TTYD_ASSET}\"" | cut -d'"' -f4 | head -n1)
  [[ -n "$TTYD_DL" ]] || fail "could not resolve ttyd asset URL (${TTYD_ASSET})."
  curl -fL --retry 5 --retry-all-errors --connect-timeout 15 -o /tmp/ttyd "$TTYD_DL" \
    || fail "ttyd download failed from: ${TTYD_DL}"
fi
install -m 0755 /tmp/ttyd "$TTYD_BIN"
rm -f /tmp/ttyd
"$TTYD_BIN" --version || fail "ttyd binary failed to execute."

step "[5/10] dashboard assets"
# The host installer normally pushes these files. When this script is run
# standalone (or a push was skipped), fetch the missing files from the repo.
mkdir -p "${DASH_DIR}/static"
fetch_dashboard_file() {
  local rel="$1" dest="${DASH_DIR}/$1"
  [[ -s "$dest" ]] && return 0
  mkdir -p "$(dirname "$dest")"
  echo "Fetching ${RAW_REPO_BASE}/dashboard/${rel}"
  curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 \
    -o "$dest" "${RAW_REPO_BASE}/dashboard/${rel}" \
    || fail "dashboard download failed: ${RAW_REPO_BASE}/dashboard/${rel}"
}
for rel in server.py static/index.html static/app.js static/styles.css static/favicon.svg; do
  fetch_dashboard_file "$rel"
done
chmod 0755 "${DASH_DIR}/server.py"
chmod 0644 "${DASH_DIR}"/static/*
python3 -m py_compile "${DASH_DIR}/server.py" \
  || fail "dashboard server.py failed to compile."

step "[6/10] bun runtime + community plugins"
# Bun is required by the herdr TUI plugin builds (e.g. ovis) and by shepherdr's web app build.
if ! command -v bun >/dev/null 2>&1; then
  echo "Installing bun (https://bun.sh/install)..."
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 https://bun.sh/install | bash
fi
mkdir -p /root/.bun
export PATH="/root/.bun/bin:${PATH}"
[[ -x /root/.bun/bin/bun ]] || fail "bun is still missing at /root/.bun/bin/bun."

# Community plugins via the herdr plugin manager (GitHub sources: owner/repo[/subdir][@ref]).
# Unset/empty HERDR_PLUGINS means "no extra plugins beyond the defaults".
# Optional "@ref" pins a release tag/commit (z.B. "aemrebarut/herdr-dagr@v0.3.1") -
# moving branch heads can drift from released revisions and break the plugin build.
# Community plugins are optional: a failing plugin must not abort the core stack.
# shellcheck disable=SC2086  # HERDR_PLUGINS is a space-separated list on purpose
for spec in ${HERDR_PLUGINS:-}; do
  [[ -n "${spec}" ]] || continue
  plugin="${spec%%@*}"
  ref="${spec#*@}"
  step "community plugin: ${plugin}"
  if [[ -n "${ref}" ]]; then
    "$HERDR_BIN" plugin install --yes --ref "${ref}" "${plugin}" \
      || echo "WARN: community plugin install failed: ${spec} - continuing without it." >&2
  else
    "$HERDR_BIN" plugin install --yes "${plugin}" \
      || echo "WARN: community plugin install failed: ${spec} - continuing without it." >&2
  fi
done

step "[7/10] shepherdr (mission control: background work + web app)"
SHEPHERDR_DIR="/opt/shepherdr"
if [[ ! -f "${SHEPHERDR_DIR}/install.sh" ]]; then
  git clone --depth 1 https://github.com/eliasstravik/shepherdr.git "${SHEPHERDR_DIR}"
fi
if [[ ! -x "${SHEPHERDR_DIR}/install.sh" ]]; then
  fail "shepherdr checkout is missing its installer: ${SHEPHERDR_DIR}/install.sh"
fi
if ! (cd "${SHEPHERDR_DIR}" && ./install.sh --web --yes); then
  echo "WARN: shepherdr web install failed - the core herdr stack continues without it." >&2
fi

step "[8/10] systemd units + credentials"
# One credentials + optional OpenRouter key file for the web services (root-only, not world-readable).
install -m 0600 /dev/null /etc/default/herdr-web
{
  echo "WEB_USER=${WEB_USER}"
  echo "WEB_PW=${WEB_PW}"
  echo "WEB_PORT=${WEB_PORT}"
  echo "DASH_PORT=${DASH_PORT}"
  if [[ -n "${OPENROUTER_API_KEY}" ]]; then
    echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY}"
  fi
  if [[ -n "${OPENROUTER_MODEL}" ]]; then
    echo "OPENROUTER_MODEL=${OPENROUTER_MODEL}"
  fi
} > /etc/default/herdr-web
chmod 600 /etc/default/herdr-web
# Remove the pre-1.0 credentials file; both units now read herdr-web.
rm -f /etc/default/ttyd-herdr

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
# Bun lives in /root/.bun/bin and is needed by TUI plugin builds (e.g. ovis) and by shepherdr's web app build.
Environment=PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=/etc/default/herdr-web
ExecStart=/usr/local/bin/herdr server
Restart=always
RestartSec=3
ExecStartPost=/bin/sh -c 'for i in $(seq 1 15); do /usr/local/bin/herdr status >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ttyd.service <<'EOF'
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
EnvironmentFile=/etc/default/herdr-web
ExecStart=/bin/sh -c 'exec /usr/local/bin/ttyd -W -p "$WEB_PORT" -c "$WEB_USER:$WEB_PW" /usr/local/bin/herdr'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/herdr-dashboard.service <<'EOF'
[Unit]
Description=herdr web dashboard
After=network-online.target herdr.service
Wants=network-online.target
Requires=herdr.service

[Service]
Type=simple
User=root
Environment=HOME=/root
EnvironmentFile=/etc/default/herdr-web
ExecStart=/usr/bin/python3 /opt/herdr-dashboard/server.py
Restart=always
RestartSec=3
ExecStartPost=/bin/sh -c 'for i in $(seq 1 20); do curl -fsS "http://127.0.0.1:${DASH_PORT}/healthz" >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable herdr.service ttyd.service herdr-dashboard.service
systemctl restart herdr.service
systemctl restart ttyd.service
systemctl restart herdr-dashboard.service

step "[9/10] service status"
sleep 4
systemctl is-active herdr.service \
  || { journalctl -u herdr --no-pager -n 50; exit 6; }
systemctl is-active ttyd.service \
  || { journalctl -u ttyd --no-pager -n 50; exit 6; }
systemctl is-active herdr-dashboard.service \
  || { journalctl -u herdr-dashboard --no-pager -n 50; exit 6; }
"$HERDR_BIN" status >/dev/null 2>&1 \
  || { journalctl -u herdr --no-pager -n 50; exit 7; }

step "[10/10] self-check"
# ttyd auth: correct credentials must return 200, wrong ones 401
CODE_OK=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "${WEB_USER}:${WEB_PW}" "http://127.0.0.1:${WEB_PORT}/" || echo 000)
CODE_BAD=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "wrong:wrong" "http://127.0.0.1:${WEB_PORT}/" || echo 000)
if [[ "$CODE_OK" != "200" || "$CODE_BAD" != "401" ]]; then
  journalctl -u ttyd --no-pager -n 50
  fail "ttyd auth check failed (ok=${CODE_OK}, bad=${CODE_BAD})."
fi

# dashboard auth + API: wait for the socket, then read one snapshot
DASH_OK=0
for _ in $(seq 1 20); do
  CODE_DASH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "${WEB_USER}:${WEB_PW}" "http://127.0.0.1:${DASH_PORT}/" || echo 000)
  CODE_DASH_BAD=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "wrong:wrong" "http://127.0.0.1:${DASH_PORT}/" || echo 000)
  SNAP_OK=$(curl -s --max-time 8 -u "${WEB_USER}:${WEB_PW}" "http://127.0.0.1:${DASH_PORT}/api/snapshot" \
    | jq -r '.ok // false' 2>/dev/null || echo false)
  if [[ "$CODE_DASH" == "200" && "$CODE_DASH_BAD" == "401" && "$SNAP_OK" == "true" ]]; then
    DASH_OK=1
    break
  fi
  sleep 2
done
if [[ "$DASH_OK" != "1" ]]; then
  journalctl -u herdr-dashboard --no-pager -n 80
  fail "dashboard check failed (ok=${CODE_DASH:-?}, bad=${CODE_DASH_BAD:-?}, snapshot=${SNAP_OK:-0})."
fi

# Machine-readable credential line for the host script (single line, easy to parse)
echo "HERDR_WEB_CREDENTIALS user=${WEB_USER} password=${WEB_PW} port=${WEB_PORT} dash_port=${DASH_PORT}"
echo "IN-CONTAINER INSTALL OK"
