#!/usr/bin/env bash
# Network-online helper for the herdr LXC (optional drop-in).
# Ensures the routing/DNS inside the container is treated as "online" before
# herdr.service starts, so agent panes that need network don't race DNS.
# Installed to /etc/network/if-pre-up.d/ by herdr-install.sh when present.
set -euo pipefail
[[ "${IFACE:-}" == "eth0" ]] || exit 0
# best-effort: nothing to configure for DHCP; hook exists for future use
exit 0
