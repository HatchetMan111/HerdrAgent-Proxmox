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
HERDR_VERSION="${HERDR_VERSION:-0.8.2}"        # upstream release tag (without 'v')
CT_HOSTNAME="herdr"
CT_DISK_STORE="${CT_DISK_STORE:-local-lvm}"   # Proxmox storage for the CT disk
WEB_PORT=7681                                  # ttyd web terminal port
PUSH_FILES=(herdr-install.sh herdr.service ttyd.service)

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
  echo ' |_||_|___|___|\___/|___|_|\_/_/ \_\_|_\'
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
fi
CT_ID="${CT_ID:-$DEFAULT_CT_ID}"
CT_CORES="${CT_CORES:-2}"
CT_RAM="${CT_RAM:-2048}"
CT_DISK="${CT_DISK:-8}"

for v in "$CT_ID" "$CT_CORES" "$CT_RAM" "$CT_DISK"; do
  [[ "$v" =~ ^[0-9]+$ ]] || die "$LINENO" "Invalid numeric value: '$v'"
done

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
  if [[ -f /root/.ssh/id_rsa.pub ]]; then
    SSH_KEY_ARGS=(--ssh-keys /root/.ssh/id_rsa.pub)
    msg_ok "Injecting host SSH key (/root/.ssh/id_rsa.pub)."
  else
    msg_info "No /root/.ssh/id_rsa.pub on host - a random root password will be set instead."
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
    --start 0 \
    "${SSH_KEY_ARGS[@]}"

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
    curl -fsSL --retry 3 --connect-timeout 15 -o "${STAGING_DIR}/${f}" \
      "${RAW_REPO_BASE}/ct/${f}" \
      || die "$LINENO" "Download failed: ${RAW_REPO_BASE}/ct/${f}"
  fi
  [[ -s "${STAGING_DIR}/${f}" ]] || die "$LINENO" "Downloaded file is empty: ${RAW_REPO_BASE}/ct/${f}"
  pct push "$CT_ID" "${STAGING_DIR}/${f}" "/root/${f}" --perms 0755
done

# Random root password (guarantees SSH login even without host SSH key)
ROOT_PW="$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 16 || true)"
[[ -n "$ROOT_PW" ]] || ROOT_PW="herdr$(date +%s)"

# ----------------------------------------------------------------------------
# Run in-container installer
# ----------------------------------------------------------------------------
msg_info "Running in-container installer (apt, ssh, herdr, ttyd, systemd)..."
if ! pct exec "$CT_ID" -- bash /root/herdr-install.sh "$HERDR_VERSION" "$ROOT_PW"; then
  msg_err "In-container installer failed. Container journal (last 100 lines):"
  pct exec "$CT_ID" -- journalctl --no-pager -n 100 || true
  pct exec "$CT_ID" -- cat /root/herdr-install.log || true
  die "$LINENO" "In-container installation failed - full output above."
fi
msg_ok "In-container installation complete."

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
msg_info "Verifying services..."
SVC_HERDR=$(pct exec "$CT_ID" -- systemctl is-active herdr 2>/dev/null || true)
SVC_TTYD=$(pct exec "$CT_ID" -- systemctl is-active ttyd 2>/dev/null || true)
if [[ "$SVC_HERDR" != "active" ]]; then
  pct exec "$CT_ID" -- journalctl -u herdr --no-pager -n 50 || true
  die "$LINENO" "herdr.service not active (status: ${SVC_HERDR:-unknown})."
fi
if [[ "$SVC_TTYD" != "active" ]]; then
  pct exec "$CT_ID" -- journalctl -u ttyd --no-pager -n 50 || true
  die "$LINENO" "ttyd.service not active (status: ${SVC_TTYD:-unknown})."
fi
msg_ok "systemd services active: herdr=active, ttyd=active"

msg_info "Verifying herdr server (status)..."
if ! pct exec "$CT_ID" -- bash -c 'timeout 10 /usr/local/bin/herdr status >/dev/null 2>&1'; then
  pct exec "$CT_ID" -- bash -c 'journalctl -u herdr --no-pager -n 80; ls -la /root/.config/herdr/ 2>/dev/null' || true
  die "$LINENO" "herdr server does not answer 'herdr status'."
fi
msg_ok "herdr server is running."

msg_info "Verifying web terminal (http://${CT_IP}:${WEB_PORT})..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${CT_IP}:${WEB_PORT}/" || echo 000)
[[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]] \
  || { pct exec "$CT_ID" -- journalctl -u ttyd --no-pager -n 80 || true
       die "$LINENO" "Web terminal not reachable (HTTP ${HTTP_CODE})."; }
msg_ok "Web terminal reachable: http://${CT_IP}:${WEB_PORT} (HTTP ${HTTP_CODE})"

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
echo "   Web terminal:  http://${CT_IP}:${WEB_PORT}"
echo "                  Basic-Auth: herdr / herdr  (change it! see README)"
echo "   SSH:           ssh root@${CT_IP}"
if [[ -f /root/.ssh/id_rsa.pub ]]; then
  echo "                  (host key injected: ${CT_IP} is your id_rsa)"
else
  echo "   Root password: ${ROOT_PW}   <- change: pct exec ${CT_ID} -- passwd"
fi
echo "  ------------------------------------------------------------"
echo "   herdr server:  pct exec ${CT_ID} -- systemctl status herdr"
echo "   Update:        pct exec ${CT_ID} -- herdr update"
echo "   Reboot test:   pct reboot ${CT_ID} && sleep 25 && pct exec ${CT_ID} -- systemctl is-active herdr ttyd"
echo "  ------------------------------------------------------------"
echo "   Debug log:     ${DEBUG_LOG}"
echo "  ============================================================"
echo
