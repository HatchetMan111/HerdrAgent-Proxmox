#!/usr/bin/env bash
# ============================================================================
# Proxmox VE LXC Installer - herdr (the runtime your coding agents live on)
#
# Community-Scripts-style one-liner (installs an unprivileged Debian 12 LXC
# running the herdr server + a ttyd web terminal):
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/herdr.sh)"
#
# Idempotent: safe to re-run. Existing CT with the same hostname is detected
# and only the in-container installation is refreshed.
#
# Requirements: Proxmox VE host (root), internet access, >= 8 GB free on the
# chosen storage.
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Variables (edit to your liking before hosting in your own repo)
# ----------------------------------------------------------------------------
RAW_REPO_BASE="${RAW_REPO_BASE:-https://raw.githubusercontent.com/HatchetMan111/HerdrAgent-Proxmox/main}"
HERDR_VERSION="${HERDR_VERSION:-0.8.2}"        # upstream release tag (without 'v')

CT_HOSTNAME="herdr"
CT_TEMPLATE_FALLBACK="debian-12-standard"     # template name hint for pveam download
CT_DISK_STORE="${CT_DISK_STORE:-local-lvm}"   # Proxmox storage for CT disk
WEB_PORT=7681                                  # ttyd web terminal port

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
command -v pveversion >/dev/null 2>&1 || { echo "ERROR: This script must run on a Proxmox VE host as root." >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Root privileges required (run as root on the PVE host)." >&2
  exit 1
fi

header_info() {
  echo
  echo '  _  _ ___ _    ___  ___ _  _   _   ___ '
  echo ' | || | __| |  / _ \| __| \| | /_\ | _ \"'
  echo ' | __ | _|| |_| (_) | _|| .` |/ _ \|   /'
  echo ' |_||_|___|___|\___/|___|_|\_/_/ \_\_|_\'
  echo '        LXC installer for Proxmox VE'
  echo
}

msg_ok()   { echo -e "  [ \033[1;32mOK\033[0m ] $*"; }
msg_info() { echo -e "  [ \033[1;34m..\033[0m ] $*"; }
msg_err()  { echo -e "  [ \033[1;31mERR\033[0m ] $*" >&2; }

die() {
  echo
  echo -e "  ====================================================================" >&2
  echo -e "  INSTALLATION FAILED at line ${1:-unknown}" >&2
  if [[ "${2:-}" != "" ]]; then
    echo -e "  Message: ${*:2}" >&2
  fi
  echo -e "  --------------------------------------------------------------------" >&2
  echo -e "  Debug log: ${DEBUG_LOG}" >&2
  echo -e "  Re-run with full trace:" >&2
  echo -e "    bash -x ${SCRIPT_PATH}" >&2
  echo -e "  ====================================================================" >&2
  trap - ERR
  exit 1
}

on_error() {
  die "$1" "Uncaught error. See the complete log above and ${DEBUG_LOG}."
}

# capture full debug log (always on, like the "bash -x log" requirement)
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEBUG_DIR="/tmp/herdr-proxmox-debug"
mkdir -p "$DEBUG_DIR"
DEBUG_LOG="${DEBUG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

exec 5>&1 6>&2
exec > >(tee -a "$DEBUG_LOG") 2>&1

trap 'on_error $LINENO' ERR
set -x

header_info
msg_info "Debug log: ${DEBUG_LOG}"

# ----------------------------------------------------------------------------
# Idempotency / CT selection
# ----------------------------------------------------------------------------
next_ct_id() {
  local max=0 id
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] && (( id > max )) && max="$id"
  done < <(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
           | grep -oE '"vmid":\s*[0-9]+' | grep -oE '[0-9]+')
  echo $(( max + 1 ))
}

read -rp "Enter CT ID [default: $(next_ct_id)]: " CT_ID
CT_ID="${CT_ID:-$(next_ct_id)}"
if ! [[ "$CT_ID" =~ ^[0-9]+$ ]]; then
  die "$LINENO" "Invalid CT ID: '${CT_ID}'"
fi

# Simple resource prompt (defaults 2 cores / 2048 MiB / 8 GiB)
read -rp "Cores  [default: 2]: " CT_CORES;  CT_CORES="${CT_CORES:-2}"
read -rp "RAM MiB [default: 2048]: " CT_RAM; CT_RAM="${CT_RAM:-2048}"
read -rp "Disk GiB [default: 8]: " CT_DISK; CT_DISK="${CT_DISK:-8}"

# ----------------------------------------------------------------------------
# Choose template storage + template
# ----------------------------------------------------------------------------
TEMPLATE_STORAGE=$(pveam status --output-format json 2>/dev/null \
  | grep -oE '"storage":[^,]+' | cut -d'"' -f4 | head -n1) || true
[[ -z "$TEMPLATE_STORAGE" ]] && TEMPLATE_STORAGE="local"

TEMPLATE_NAME=$(pveam list "$TEMPLATE_STORAGE" --output-format json 2>/dev/null \
  | grep -oE '"volid":[^,]+' | cut -d'"' -f4 \
  | grep -E "debian-12.*standard.*\.tar\.(gz|xz)$" | sort -V | tail -n1) || true

if [[ -z "$TEMPLATE_NAME" ]]; then
  msg_info "Downloading Debian 12 LXC template to storage '${TEMPLATE_STORAGE}'..."
  pveam update "$TEMPLATE_STORAGE" >/dev/null 2>&1 || true
  pveam download "$TEMPLATE_STORAGE" "${CT_TEMPLATE_FALLBACK}" >/dev/null
  TEMPLATE_NAME="${TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE_FALLBACK}_${CT_TEMPLATE_FALLBACK##*}_amd64.tar.gz"
  # fix volid pattern if pveam named it differently
  TEMPLATE_NAME=$(pveam list "$TEMPLATE_STORAGE" --output-format json 2>/dev/null \
    | grep -oE '"volid":[^,]+' | cut -d'"' -f4 \
    | grep -E "debian-12.*standard.*\.tar\.(gz|xz)$" | sort -V | tail -n1)
  [[ -z "$TEMPLATE_NAME" ]] && die "$LINENO" "Could not locate a Debian 12 template in storage '${TEMPLATE_STORAGE}'."
fi
msg_ok "Template: ${TEMPLATE_NAME}"

# ----------------------------------------------------------------------------
# Idempotency check: re-run on an existing CT
# ----------------------------------------------------------------------------
EXISTING_CT=""
if pvesh get "/nodes/$(hostname)/lxc/${CT_ID}" >/dev/null 2>&1; then
  EXISTING_CT="yes"
  msg_info "CT ${CT_ID} already exists - refreshing installation inside it (idempotent path)."
fi

# ----------------------------------------------------------------------------
# Create the container (skip if it already exists)
# ----------------------------------------------------------------------------
if [[ -z "$EXISTING_CT" ]]; then
  msg_info "Creating LXC ${CT_ID} (${CT_CORES} cores, ${CT_RAM} MiB RAM, ${CT_DISK} GiB disk)..."
  STORAGE_CHOICES=$(pvesm status --content rootdir --output-format json 2>/dev/null | grep -oE '"storage":[^,]+' | cut -d'"' -f4)
  [[ -z "$STORAGE_CHOICES" ]] && die "$LINENO" "No storage with rootdir content found. Check: pvesm status"

  # Fallback if the configured default storage is not present on this node
  if ! printf '%s\n' "$STORAGE_CHOICES" | grep -qx "${CT_DISK_STORE}"; then
    CT_DISK_STORE=$(printf '%s\n' "$STORAGE_CHOICES" | head -n1)
    msg_info "Configured storage not found - using '${CT_DISK_STORE}' instead."
  fi

  pct create "$CT_ID" "$TEMPLATE_NAME" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_RAM" \
    --rootfs "${CT_DISK_STORE}:${CT_DISK}" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=0 \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0 \
    --ssh-keys /root/.ssh/id_rsa.pub 2>/dev/null \
    || pct create "$CT_ID" "$TEMPLATE_NAME" \
         --hostname "$CT_HOSTNAME" \
         --cores "$CT_CORES" \
         --memory "$CT_RAM" \
         --rootfs "${CT_DISK_STORE}:${CT_DISK}" \
         --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=0 \
         --unprivileged 1 \
         --features nesting=1 \
         --onboot 1 \
         --start 0

  msg_ok "Container ${CT_ID} created (unprivileged, onboot enabled, DHCP network)."
fi

# ----------------------------------------------------------------------------
# Start CT (wait for network)
# ----------------------------------------------------------------------------
if ! pct status "$CT_ID" 2>/dev/null | grep -q running; then
  pct start "$CT_ID"
fi
msg_info "Waiting for container network (DHCP)..."
sleep 5
CT_IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -n1)
RETRY=0
while [[ -z "$CT_IP" && "$RETRY" -lt 20 ]]; do
  sleep 2; RETRY=$((RETRY+1))
  CT_IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -n1)
done
[[ -z "$CT_IP" ]] && die "$LINENO" "Container did not get an IPv4 address on eth0 within 45s. Check your DHCP/bridge setup (vmbr0)."
msg_ok "Container IP: ${CT_IP}"

# ----------------------------------------------------------------------------
# Push in-container installer + service units, then run it
# ----------------------------------------------------------------------------
for f in herdr-install.sh herdr.service ttyd.service 60-herdr.sh; do
  # Allow both local file paths (when run from a git checkout) and raw GitHub
  if [[ -f "$(dirname "$SCRIPT_PATH")/../ct/${f}" ]]; then
    pct push "$CT_ID" "$(dirname "$SCRIPT_PATH")/../ct/${f}" "/root/${f}" --perms 0755
  else
    pct exec "$CT_ID" -- bash -c "wget -qO /root/${f} ${RAW_REPO_BASE}/ct/${f} && chmod +x /root/${f}"
  fi
done

msg_info "Running in-container installer (apt, herdr binary, ttyd, systemd)..."
if ! pct exec "$CT_ID" -- bash -exc 'bash -x /root/herdr-install.sh'; then
  msg_err "In-container installer failed. Full journal of the container:"
  pct exec "$CT_ID" -- bash -c 'journalctl --no-pager -n 100 || true'
  pct exec "$CT_ID" -- bash -c 'cat /root/herdr-install.log 2>/dev/null || true'
  die "$LINENO" "In-container installation failed - see full output above (apt/herdr/ttyd)."
fi
msg_ok "In-container installation complete."

# ----------------------------------------------------------------------------
# Verification (service, herdr socket, web terminal, ssh)
# ----------------------------------------------------------------------------
msg_info "Verifying services..."
SVC_HERDR=$(pct exec "$CT_ID" -- systemctl is-active herdr) || true
SVC_TTYD=$(pct exec "$CT_ID" -- systemctl is-active ttyd) || true
[[ "$SVC_HERDR" != "active" ]] && { pct exec "$CT_ID" -- journalctl -u herdr --no-pager -n 50; die "$LINENO" "herdr.service not active (status: ${SVC_HERDR})."; }
[[ "$SVC_TTYD"  != "active" ]] && { pct exec "$CT_ID" -- journalctl -u ttyd --no-pager -n 50; die "$LINENO" "ttyd.service not active (status: ${SVC_TTYD})."; }
msg_ok "systemd services active: herdr=${SVC_HERDR}, ttyd=${SVC_TTYD}"

msg_info "Verifying herdr server socket (ping)..."
if ! pct exec "$CT_ID" -- bash -c 'timeout 10 /usr/local/bin/herdr status >/dev/null 2>&1'; then
  pct exec "$CT_ID" -- bash -c 'journalctl -u herdr --no-pager -n 80; ls -la /root/.config/herdr/ 2>/dev/null'
  die "$LINENO" "herdr socket ping failed - server not responding."
fi
msg_ok "herdr server answers ping on its unix socket."

msg_info "Verifying web terminal (http://${CT_IP}:${WEB_PORT})..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${CT_IP}:${WEB_PORT}/" || echo 000)
[[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]] \
  || { pct exec "$CT_ID" -- journalctl -u ttyd --no-pager -n 80; die "$LINENO" "Web terminal not reachable (HTTP ${HTTP_CODE})."; }
msg_ok "Web terminal reachable: http://${CT_IP}:${WEB_PORT} (HTTP ${HTTP_CODE})"

msg_info "Verifying SSH login..."
pct exec "$CT_ID" -- bash -c 'systemctl is-active ssh || systemctl is-active sshd' >/dev/null 2>&1 \
  || die "$LINENO" "SSH daemon not running in container."
msg_ok "SSH daemon active in container."

# Enable onboot safety (already set at create, idempotent re-assert)
pct set "$CT_ID" --onboot 1

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "  ============================================================"
echo "   herdr LXC installed successfully."
echo "  ------------------------------------------------------------"
echo "   CT ID:        ${CT_ID}"
echo "   CT IP:        ${CT_IP} (DHCP)"
echo "   Web terminal: http://${CT_IP}:${WEB_PORT}"
echo "   SSH:          ssh root@${CT_IP}  (run 'herdr' there to attach)"
echo "  ------------------------------------------------------------"
echo "   herdr server: systemctl status herdr   (in CT: pct enter ${CT_ID})"
echo "   Update:       pct exec ${CT_ID} -- herdr update"
echo "   Reboot test:  pct reboot ${CT_ID} && sleep 20 && pct exec ${CT_ID} -- systemctl is-active herdr ttyd"
echo "  ------------------------------------------------------------"
echo "   Debug log:    ${DEBUG_LOG}"
echo "  ============================================================"
echo
