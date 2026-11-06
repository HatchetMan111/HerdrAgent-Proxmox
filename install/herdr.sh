#!/usr/bin/env bash
# ============================================================================
# Proxmox VE LXC Installer - herdr (the runtime your coding agents live on)
#
# One-liner (run as root on the PVE host):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main/install/herdr.sh)"
#
# Full trace mode: prefix the one-liner with TRACE=1
#
# Idempotent: safe to re-run. Existing CT with the same ID is detected and
# only the in-container installation is refreshed.
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Variables
# ----------------------------------------------------------------------------
RAW_REPO_BASE="${RAW_REPO_BASE:-https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main}"
HERDR_VERSION="${HERDR_VERSION:-0.9.5}"        # upstream release tag (without 'v') or "latest"
CT_HOSTNAME="herdr"
CT_DISK_STORE="${CT_DISK_STORE:-local-lvm}"   # Proxmox storage for the CT disk
WEB_PORT="${WEB_PORT:-7681}"                  # ttyd web terminal port
DASH_PORT="${DASH_PORT:-8080}"                # herdr web dashboard port
OPENROUTER_KEY="${OPENROUTER_KEY:-}"        # optional OpenRouter API-Key (OpenRouter)
OPENROUTER_MODEL="${OPENROUTER_MODEL:-}"    # optional OpenRouter-Modell (ANTHROPIC_MODEL), leer = OpenRouter Default
HERDR_PLUGINS="${HERDR_PLUGINS:-aemrebarut/herdr-dagr devswha/ovis}"  # space-separated: owner/repo[/subdir] community plugins
PUSH_FILES=(herdr-install.sh)
DASHBOARD_FILES=(
  dashboard/server.py
  dashboard/static/index.html
  dashboard/static/app.js
  dashboard/static/styles.css
  dashboard/static/favicon.svg
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
msg_ok()   { echo -e "  [ \033[1;32mOK\033[0m ] $*"; }
msg_info() { echo -e "  [ \033[1;34m..\033[0m ] $*"; }
msg_err()  { echo -e "  [ \033[1;31mERR\033[0m ] $*" >&2; }

header_info() {
  echo
  echo '  _  _ ___ _    ___  ___ _  _   _   ___ '
  echo ' | || | __| |  / _ \| __| \| | /_\ | _ \"'
  echo ' | __ | _|| |_| (_) | _|| .` |/ _ \|   /'
  echo ' |_||_|___|___|\___/|___|_|\_/_/ \_\_|_ '
  echo '        LXC installer for Proxmox VE'
  echo
}

command -v pveversion >/dev/null 2>&1 || { msg_err "This script must run on a Proxmox VE host as root."; exit 1; }
[[ "$(id -u)" -eq 0 ]] || { msg_err "Root privileges required (run as root on the PVE host)."; exit 1; }
command -v curl >/dev/null 2>&1 || { msg_err "curl is required on the PVE host."; exit 1; }

DEBUG_DIR="/tmp/herdr-proxmox-debug"
mkdir -p "$DEBUG_DIR"
DEBUG_LOG="${DEBUG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

die() {
  local line="${1:-unknown}"
  local msg="${2:-}"
  echo
  echo -e "  ====================================================================" >&2
  echo -e "  INSTALLATION FAILED at line ${line}" >&2
  [[ -n "$msg" ]] && echo -e "  Message: ${msg}" >&2
  echo -e "  --------------------------------------------------------------------" >&2
  echo -e "  Debug log: ${DEBUG_LOG}" >&2
  echo -e "  Re-run with full trace (bash -x):" >&2
  echo -e "    TRACE=1 bash -c \"\$(wget -qLO - ${RAW_REPO_BASE%/ct/*}/install/herdr.sh)\"" >&2
  echo -e "  ====================================================================" >&2
  trap - ERR
  exit 1
}

# Log everything (stdout+stderr) to the debug log while still showing it
exec > >(tee -a "$DEBUG_LOG") 2>&1

trap 'die "$LINENO" "Uncaught error - see complete log: ${DEBUG_LOG}"' ERR
[[ "${TRACE:-0}" == "1" ]] && set -x

header_info
msg_info "Debug log: ${DEBUG_LOG}"

# Resolve "latest" once on the host (the container then downloads a fixed tag).
if [[ "$HERDR_VERSION" == "latest" ]]; then
  RESOLVED_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' --retry 3 \
    https://github.com/herdrdev/herdr/releases/latest 2>/dev/null \
    | sed -n 's#.*/tag/v##p' || true)
  if [[ -n "$RESOLVED_VERSION" ]]; then
    HERDR_VERSION="$RESOLVED_VERSION"
    msg_ok "Latest herdr release: v${HERDR_VERSION}"
  else
    HERDR_VERSION="0.9.5"
    msg_info "Could not resolve the latest herdr release - falling back to v${HERDR_VERSION}."
  fi
fi

# ----------------------------------------------------------------------------
# CT selection (interactive only when attached to a TTY)
# ----------------------------------------------------------------------------
next_ct_id() {
  local max=100 id
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    (( id > max )) && max="$id"
  done < <(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
           | grep -oE '"vmid":\s*[0-9]+' | grep -oE '[0-9]+' || true)
  echo $(( max + 1 ))
}

DEFAULT_CT_ID=$(next_ct_id)
INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1

if [[ "$INTERACTIVE" == "1" ]]; then
  read -rp "CT ID [${DEFAULT_CT_ID}]: " CT_ID
  read -rp "Cores [2]: " CT_CORES
  read -rp "RAM in MiB [2048]: " CT_RAM
  read -rp "Disk in GiB [8]: " CT_DISK
  # read -rp from a TTY is interruptible (Ctrl+C aborts the script cleanly);
  # the key is only stored when the user actually enters one.
  read -rp "OpenRouter API-Key (optional, fuer Agenten via OpenRouter, Enter = ueberspringen): " OPENROUTER_KEY_PROMPT
  if [[ -n "${OPENROUTER_KEY_PROMPT:-}" ]]; then
    OPENROUTER_KEY="${OPENROUTER_KEY_PROMPT}"
  fi
  read -rp "OpenRouter Modell (optional, z.B. anthropic/claude-sonnet-4.6; Leer = OpenRouter Default): " OPENROUTER_MODEL_PROMPT
  if [[ -n "${OPENROUTER_MODEL_PROMPT:-}" ]]; then
    OPENROUTER_MODEL="${OPENROUTER_MODEL_PROMPT}"
  fi
fi
CT_ID="${CT_ID:-$DEFAULT_CT_ID}"
CT_CORES="${CT_CORES:-2}"
CT_RAM="${CT_RAM:-2048}"
CT_DISK="${CT_DISK:-8}"

for v in "$CT_ID" "$CT_CORES" "$CT_RAM" "$CT_DISK" "$WEB_PORT" "$DASH_PORT"; do
  [[ "$v" =~ ^[0-9]+$ ]] || die "$LINENO" "Invalid numeric value: '$v'"
done
(( WEB_PORT < 1 || WEB_PORT > 65535 )) && die "$LINENO" "WEB_PORT out of range: ${WEB_PORT}"
(( DASH_PORT < 1 || DASH_PORT > 65535 )) && die "$LINENO" "DASH_PORT out of range: ${DASH_PORT}"
[[ "$WEB_PORT" != "$DASH_PORT" ]] || die "$LINENO" "WEB_PORT and DASH_PORT must differ."

# ----------------------------------------------------------------------------
# Locate Debian 12 template (searches all vztmpl storages, downloads if needed)
# ----------------------------------------------------------------------------
VZTMPL_STORAGES=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}')
[[ -n "$VZTMPL_STORAGES" ]] || die "$LINENO" "No storage with 'vztmpl' content found. Check: pvesm status"

TEMPLATE_NAME=""
TEMPLATE_STORAGE=""
for S in $VZTMPL_STORAGES; do
  T=$(pveam list "$S" 2>/dev/null | awk 'NR>1{print $1}' \
     | grep -E 'debian-12-standard.*amd64.*\.tar\.(gz|xz|zst)$' | sort -V | tail -n1)
  if [[ -n "$T" ]]; then TEMPLATE_STORAGE="$S"; TEMPLATE_NAME="$T"; break; fi
done

if [[ -z "$TEMPLATE_NAME" ]]; then
  # Intentionally unquoted: split the newline-separated storage list.
  # shellcheck disable=SC2086
  TEMPLATE_STORAGE="$(printf '%s\n' $VZTMPL_STORAGES | head -n1)"
  msg_info "No Debian 12 template cached - downloading to '${TEMPLATE_STORAGE}'..."
  pveam update >/dev/null 2>&1 || true
  DL_NAME=$(pveam available 2>/dev/null | awk '/debian-12-standard/ && /amd64/ {print $2}' | sort -V | tail -n1)
  [[ -n "$DL_NAME" ]] || die "$LINENO" "No Debian 12 template found in 'pveam available'."
  pveam download "$TEMPLATE_STORAGE" "$DL_NAME"
  TEMPLATE_NAME=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1{print $1}' \
     | grep -E 'debian-12-standard.*amd64.*\.tar\.(gz|xz|zst)$' | sort -V | tail -n1)
  [[ -n "$TEMPLATE_NAME" ]] || die "$LINENO" "Template download failed on storage '${TEMPLATE_STORAGE}'."
fi
msg_ok "Template: ${TEMPLATE_NAME}"

# ----------------------------------------------------------------------------
# Detect network bridge (prefer vmbr0)
# ----------------------------------------------------------------------------
BRIDGE="vmbr0"
if ! ip link show vmbr0 >/dev/null 2>&1; then
  BRIDGE=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | head -n1)
fi
[[ -n "$BRIDGE" ]] || die "$LINENO" "No network bridge found on this host."
msg_ok "Network bridge: ${BRIDGE}"

# ----------------------------------------------------------------------------
# Idempotency: existing CT with this ID -> refresh installation only
# ----------------------------------------------------------------------------
EXISTING_CT="no"
if pct status "$CT_ID" >/dev/null 2>&1; then
  EXISTING_CT="yes"
  msg_info "CT ${CT_ID} already exists - refreshing installation inside it (idempotent)."
fi

# ----------------------------------------------------------------------------
# Create the container
# ----------------------------------------------------------------------------
if [[ "$EXISTING_CT" == "no" ]]; then
  msg_info "Creating LXC ${CT_ID} (${CT_CORES} cores, ${CT_RAM} MiB RAM, ${CT_DISK} GiB disk)..."

  ROOTFS_STORAGES=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1{print $1}')
  [[ -n "$ROOTFS_STORAGES" ]] || die "$LINENO" "No storage with 'rootdir' content found. Check: pvesm status"
  if ! printf '%s\n' "$ROOTFS_STORAGES" | grep -qx "$CT_DISK_STORE"; then
    CT_DISK_STORE=$(printf '%s\n' "$ROOTFS_STORAGES" | head -n1)
    msg_info "Configured disk storage not found - using '${CT_DISK_STORE}' instead."
  fi

  SSH_KEY_ARGS=()
  SSH_MANUAL_APPEND=0
  HOST_SSH_PUB=""
  for k in /root/.ssh/id_rsa.pub /root/.ssh/id_ed25519.pub; do
    if [[ -f "$k" ]]; then HOST_SSH_PUB="$k"; break; fi
  done
  if [[ -n "$HOST_SSH_PUB" ]]; then
    SSH_KEY_ARGS=(--ssh-public-keys "$HOST_SSH_PUB")
    msg_ok "Injecting host SSH key (${HOST_SSH_PUB})."
  else
    msg_info "No host SSH public key found - a random root password will be set instead."
  fi

  # --ssh-public-keys requires the option name in older PVE; probe once and fall
  # back to creating without keys (key is then appended manually after start).
  if ! pct create "$CT_ID" "$TEMPLATE_NAME" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_RAM" \
    --rootfs "${CT_DISK_STORE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=0" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0 \
    "${SSH_KEY_ARGS[@]}" 2>"${DEBUG_DIR}/pct-create-err.log"; then
    if grep -q "ssh-public-keys\|ssh-keys" "${DEBUG_DIR}/pct-create-err.log" 2>/dev/null \
       && [[ ${#SSH_KEY_ARGS[@]} -gt 0 ]]; then
      msg_info "PVE does not support --ssh-public-keys at create - appending key after start instead."
      SSH_MANUAL_APPEND=1
      SSH_KEY_ARGS=()
    else
      cat "${DEBUG_DIR}/pct-create-err.log" >&2
      die "$LINENO" "pct create failed - see pct error above."
    fi
    pct create "$CT_ID" "$TEMPLATE_NAME" \
      --hostname "$CT_HOSTNAME" \
      --cores "$CT_CORES" \
      --memory "$CT_RAM" \
      --rootfs "${CT_DISK_STORE}:${CT_DISK}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=0" \
      --unprivileged 1 \
      --features nesting=1 \
      --onboot 1 \
      --start 0
  fi

  msg_ok "Container ${CT_ID} created (unprivileged, onboot enabled, DHCP via ${BRIDGE})."
fi

# ----------------------------------------------------------------------------
# Start CT and wait for network
# ----------------------------------------------------------------------------
if ! pct status "$CT_ID" 2>/dev/null | grep -q running; then
  pct start "$CT_ID"
fi
msg_info "Waiting for container network (DHCP)..."
sleep 5
CT_IP=""
for _ in $(seq 1 25); do
  CT_IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 2>/dev/null \
          | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -n1 || true)
  [[ -n "$CT_IP" ]] && break
  sleep 2
done
[[ -n "$CT_IP" ]] || die "$LINENO" "Container got no IPv4 on eth0 within 60s (bridge ${BRIDGE}/DHCP)."
msg_ok "Container IP: ${CT_IP}"

# Manual SSH key append (fallback when pct create lacked --ssh-public-keys)
if [[ "${SSH_MANUAL_APPEND:-0}" == "1" && -n "${HOST_SSH_PUB:-}" ]]; then
  msg_info "Appending host SSH key manually..."
  pct exec "$CT_ID" -- mkdir -p /root/.ssh
  pct push "$CT_ID" "$HOST_SSH_PUB" /root/.ssh/authorized_keys --user 0 --group 0 --perms 0600
  pct exec "$CT_ID" -- chmod 700 /root/.ssh
  msg_ok "Host SSH key appended to /root/.ssh/authorized_keys."
fi

# ----------------------------------------------------------------------------
# Fetch ct/ files (from local checkout when available, else from GitHub)
# ----------------------------------------------------------------------------
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] \
   && [[ -d "$(dirname "${BASH_SOURCE[0]}")/../ct" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

STAGING_DIR="${DEBUG_DIR}/files-$$"
mkdir -p "$STAGING_DIR"
for f in "${PUSH_FILES[@]}"; do
  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/ct/${f}" ]]; then
    cp "${SCRIPT_DIR}/ct/${f}" "${STAGING_DIR}/${f}"
  else
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 -o "${STAGING_DIR}/${f}" \
      "${RAW_REPO_BASE}/ct/${f}" \
      || die "$LINENO" "Download failed: ${RAW_REPO_BASE}/ct/${f}"
  fi
  [[ -s "${STAGING_DIR}/${f}" ]] || die "$LINENO" "Downloaded file is empty: ${RAW_REPO_BASE}/ct/${f}"
  pct push "$CT_ID" "${STAGING_DIR}/${f}" "/root/${f}" --perms 0755
done

# Dashboard assets (server.py + static files). Pushed before the in-container
# installer runs so a local checkout works without network access to GitHub.
DASH_STAGE="${STAGING_DIR}/dashboard"
mkdir -p "${DASH_STAGE}/static"
for f in "${DASHBOARD_FILES[@]}"; do
  rel="${f#dashboard/}"
  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/${f}" ]]; then
    cp "${SCRIPT_DIR}/${f}" "${DASH_STAGE}/${rel}"
  else
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 \
      -o "${DASH_STAGE}/${rel}" "${RAW_REPO_BASE}/${f}" \
      || die "$LINENO" "Download failed: ${RAW_REPO_BASE}/${f}"
  fi
  [[ -s "${DASH_STAGE}/${rel}" ]] || die "$LINENO" "Dashboard file is empty: ${f}"
  pct exec "$CT_ID" -- mkdir -p "/opt/herdr-dashboard/$(dirname "$rel")"
  pct push "$CT_ID" "${DASH_STAGE}/${rel}" "/opt/herdr-dashboard/${rel}" --perms 0644
done
pct exec "$CT_ID" -- chmod 0755 /opt/herdr-dashboard/server.py
msg_ok "Dashboard assets pushed to /opt/herdr-dashboard."

# Random passwords (root SSH fallback + web terminal basic auth)
# NOTE: no `tr | head` here - that dies with SIGPIPE (141) under pipefail.
# dd reads exactly N bytes and exits cleanly, so the pipe is safe.
rand_pw() {
  local s
  # 256 bytes -> ~62 alnum chars survive tr; ${s:0:16} is then always 16 chars
  s=$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'a-zA-Z0-9' || true)
  [[ -z "$s" ]] && s="herdr$(date +%s)"
  echo "${s:0:16}"
}
ROOT_PW="$(rand_pw)"
WEB_USER="herdr"
WEB_PW=""

# Re-runs must not break existing logins: reuse the credentials already stored
# in the container (root-only file written by the in-container installer).
if [[ "$EXISTING_CT" == "yes" ]]; then
  EXISTING_CREDS=$(pct exec "$CT_ID" -- cat /etc/default/herdr-web 2>/dev/null || true)
  if [[ -n "$EXISTING_CREDS" ]]; then
    OLD_USER=$(printf '%s\n' "$EXISTING_CREDS" | sed -n 's/^WEB_USER=//p' | head -n1)
    OLD_PW=$(printf '%s\n' "$EXISTING_CREDS" | sed -n 's/^WEB_PW=//p' | head -n1)
    if [[ -n "$OLD_USER" && -n "$OLD_PW" ]]; then
      WEB_USER="$OLD_USER"
      WEB_PW="$OLD_PW"
      msg_ok "Reusing existing web credentials from /etc/default/herdr-web."
    fi
  fi
fi
[[ -n "$WEB_PW" ]] || WEB_PW="$(rand_pw)"

# Re-runs must not lose an existing OpenRouter key: reuse it from the
# credentials file written by the in-container installer.
if [[ "${EXISTING_CT:-no}" == "yes" && -z "${OPENROUTER_KEY:-}" ]]; then
  OPENROUTER_KEY="$(pct exec "$CT_ID" -- sed -n 's/^OPENROUTER_API_KEY=//p' /etc/default/herdr-web 2>/dev/null || true)"
fi
if [[ -n "${OPENROUTER_KEY:-}" ]]; then
  msg_ok "Reusing existing OpenRouter API key from /etc/default/herdr-web."
fi

# ----------------------------------------------------------------------------
# Run in-container installer
# ----------------------------------------------------------------------------
msg_info "Running in-container installer (apt, ssh, herdr, ttyd, dashboard, systemd)..."
CT_OUT="${DEBUG_DIR}/ct-out-$$"
# PIPESTATUS: only the pct exec exit code decides success (tee must not mask it)
set +e
pct exec "$CT_ID" -- bash /root/herdr-install.sh \
  "$HERDR_VERSION" "$ROOT_PW" "$WEB_USER" "$WEB_PW" "$DASH_PORT" "$RAW_REPO_BASE" "$WEB_PORT" \
  "$OPENROUTER_KEY" "$OPENROUTER_MODEL" "$HERDR_PLUGINS" \
  2>&1 | tee "$CT_OUT"
CT_RC=${PIPESTATUS[0]}
set -e
if [[ "$CT_RC" -ne 0 ]]; then
  msg_err "In-container installer failed (exit ${CT_RC}). Container journal (last 100 lines):"
  pct exec "$CT_ID" -- journalctl --no-pager -n 100 || true
  pct exec "$CT_ID" -- cat /root/herdr-install.log || true
  die "$LINENO" "In-container installation failed - full output above."
fi
msg_ok "In-container installation complete."

# Read back credentials (container may have generated its own if args were empty)
if grep -q "^HERDR_WEB_CREDENTIALS " "$CT_OUT"; then
  CRED_LINE=$(grep "^HERDR_WEB_CREDENTIALS " "$CT_OUT" | tail -n1)
  WEB_USER=$(echo "$CRED_LINE"  | sed -n 's/.*user=\([^ ]*\).*/\1/p')
  WEB_PW=$(echo "$CRED_LINE"    | sed -n 's/.*password=\([^ ]*\).*/\1/p')
  WEB_PORT=$(echo "$CRED_LINE"  | sed -n 's/.*port=\([^ ]*\).*/\1/p')
  DASH_PORT=$(echo "$CRED_LINE" | sed -n 's/.*dash_port=\([^ ]*\).*/\1/p')
fi

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
msg_info "Verifying services..."
SVC_HERDR=$(pct exec "$CT_ID" -- systemctl is-active herdr 2>/dev/null || true)
SVC_TTYD=$(pct exec "$CT_ID" -- systemctl is-active ttyd 2>/dev/null || true)
SVC_DASH=$(pct exec "$CT_ID" -- systemctl is-active herdr-dashboard 2>/dev/null || true)
if [[ "$SVC_HERDR" != "active" ]]; then
  pct exec "$CT_ID" -- journalctl -u herdr --no-pager -n 50 || true
  die "$LINENO" "herdr.service not active (status: ${SVC_HERDR:-unknown})."
fi
if [[ "$SVC_TTYD" != "active" ]]; then
  pct exec "$CT_ID" -- journalctl -u ttyd --no-pager -n 50 || true
  die "$LINENO" "ttyd.service not active (status: ${SVC_TTYD:-unknown})."
fi
if [[ "$SVC_DASH" != "active" ]]; then
  pct exec "$CT_ID" -- journalctl -u herdr-dashboard --no-pager -n 50 || true
  die "$LINENO" "herdr-dashboard.service not active (status: ${SVC_DASH:-unknown})."
fi
msg_ok "systemd services active: herdr=active, ttyd=active, herdr-dashboard=active"

msg_info "Verifying herdr server (status)..."
if ! pct exec "$CT_ID" -- bash -c 'timeout 10 /usr/local/bin/herdr status >/dev/null 2>&1'; then
  pct exec "$CT_ID" -- bash -c 'journalctl -u herdr --no-pager -n 80; ls -la /root/.config/herdr/ 2>/dev/null' || true
  die "$LINENO" "herdr server does not answer 'herdr status'."
fi
msg_ok "herdr server is running."

msg_info "Verifying web terminal (http://${CT_IP}:${WEB_PORT})..."
HTTP_ANON=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${CT_IP}:${WEB_PORT}/" || echo 000)
HTTP_AUTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "${WEB_USER}:${WEB_PW}" "http://${CT_IP}:${WEB_PORT}/" || echo 000)
if [[ "$HTTP_AUTH" != "200" ]]; then
  pct exec "$CT_ID" -- journalctl -u ttyd --no-pager -n 80 || true
  die "$LINENO" "Web terminal auth check failed (anon=${HTTP_ANON}, auth=${HTTP_AUTH}, expected 401/200)."
fi
msg_ok "Web terminal reachable + login OK: http://${CT_IP}:${WEB_PORT} (anon=${HTTP_ANON}, ${WEB_USER}:${WEB_PW} -> ${HTTP_AUTH})"

msg_info "Verifying web dashboard (http://${CT_IP}:${DASH_PORT})..."
HTTP_DASH_ANON=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${CT_IP}:${DASH_PORT}/" || echo 000)
HTTP_DASH_AUTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "${WEB_USER}:${WEB_PW}" "http://${CT_IP}:${DASH_PORT}/" || echo 000)
DASH_SNAPSHOT=$(curl -s --max-time 15 -u "${WEB_USER}:${WEB_PW}" \
  "http://${CT_IP}:${DASH_PORT}/api/snapshot" 2>/dev/null || true)
if [[ "$HTTP_DASH_AUTH" != "200" ]] \
   || ! printf '%s' "$DASH_SNAPSHOT" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
  pct exec "$CT_ID" -- journalctl -u herdr-dashboard --no-pager -n 80 || true
  die "$LINENO" "Web dashboard check failed (anon=${HTTP_DASH_ANON}, auth=${HTTP_DASH_AUTH}, snapshot=${DASH_SNAPSHOT:0:200})."
fi
msg_ok "Web dashboard reachable + API OK: http://${CT_IP}:${DASH_PORT} (anon=${HTTP_DASH_ANON}, auth=${HTTP_DASH_AUTH})"

msg_info "Verifying SSH daemon..."
pct exec "$CT_ID" -- bash -c 'systemctl is-active ssh || systemctl is-active sshd' >/dev/null 2>&1 \
  || die "$LINENO" "SSH daemon not running in container."
msg_ok "SSH daemon active in container."

pct set "$CT_ID" --onboot 1

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "  ============================================================"
echo "   herdr LXC installed successfully."
echo "  ------------------------------------------------------------"
echo "   CT ID:         ${CT_ID}"
echo "   CT IP:         ${CT_IP} (DHCP)"
echo "  ------------------------------------------------------------"
echo "   ANMELDUNG / LOGIN (bitte notieren!):"
echo ""
echo "     Web-Dashboard: http://${CT_IP}:${DASH_PORT}"
echo "     Web-Terminal:  http://${CT_IP}:${WEB_PORT}"
echo "     Benutzer:      ${WEB_USER}"
echo "     Passwort:      ${WEB_PW}"
echo ""
if [[ -n "${OPENROUTER_KEY:-}" ]]; then
  echo "     OpenRouter:    API-Key hinterlegt - neue Agenten starten damit (Claude Code via OpenRouter)."
else
  echo "     OpenRouter:    kein API-Key hinterlegt - optional im Dashboard bei der Workspace-Anlage eingetragen."
fi
if [[ -n "${OPENROUTER_MODEL:-}" ]]; then
  echo "     OpenRouter-Modell: ${OPENROUTER_MODEL} (leer = OpenRouter Default)."
fi
if [[ -n "${HERDR_PLUGINS:-}" ]]; then
  echo "     Community-Plugins: ${HERDR_PLUGINS}"
fi
echo ""
if [[ -n "${HOST_SSH_PUB:-}" ]]; then
  echo "     SSH:           ssh root@${CT_IP}   (Key: ${HOST_SSH_PUB})"
else
  echo "     SSH:           ssh root@${CT_IP}"
  echo "     Root-Passwort: ${ROOT_PW}"
fi
echo "  ------------------------------------------------------------"
echo "   Passwoerter aendern:"
echo "     Web:   pct exec ${CT_ID} -- bash -c '"
echo "            read -p \"user:pw: \" C && sed -i \"s/^WEB_PW=.*/WEB_PW=\${C#*:}/; s/^WEB_USER=.*/WEB_USER=\${C%%:*}/\" /etc/default/herdr-web && systemctl restart ttyd herdr-dashboard'"
echo "     SSH:   pct exec ${CT_ID} -- passwd"
echo "     (Web-Credentials liegen root-only in /etc/default/herdr-web)"
echo "  ------------------------------------------------------------"
echo "   herdr server:  pct exec ${CT_ID} -- systemctl status herdr"
echo "   Dashboard:     pct exec ${CT_ID} -- systemctl status herdr-dashboard"
echo "   Update:        pct exec ${CT_ID} -- herdr update"
echo "   Reboot test:   pct reboot ${CT_ID} && sleep 25 && pct exec ${CT_ID} -- systemctl is-active herdr ttyd herdr-dashboard"
echo "  ------------------------------------------------------------"
echo "   Debug log:     ${DEBUG_LOG}"
echo "  ============================================================"
echo
