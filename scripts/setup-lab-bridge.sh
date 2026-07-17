#!/usr/bin/env bash
# Create Proxmox NAT bridge vmbr1 for non-k3s / NFS VMs (internet via MASQUERADE on vmbr0).
#
# Copy to the Proxmox node and run as root, for example:
#   scp scripts/setup-lab-bridge.sh user@proxmox:/tmp/
#   ssh -t user@proxmox 'sudo bash /tmp/setup-lab-bridge.sh'
#
# See docs/lab-network.md.
set -euo pipefail

BRIDGE="${BRIDGE:-vmbr1}"
BRIDGE_CIDR="${BRIDGE_CIDR:-10.10.10.1/24}"
LAB_NET="${LAB_NET:-10.10.10.0/24}"
WAN_IFACE="${WAN_IFACE:-vmbr0}"
IFACES_D="/etc/network/interfaces.d"
IFACE_FILE="${IFACES_D}/${BRIDGE}"
NAT_SCRIPT="/usr/local/sbin/kube-lab-nat.sh"
IFUP_HOOK="/etc/network/if-up.d/kube-lab-nat"
SYSCTL_FILE="/etc/sysctl.d/99-kube-lab-forward.conf"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo bash $0)" >&2
  exit 1
fi

if [[ ! -d /etc/pve ]]; then
  echo "This does not look like a Proxmox host (/etc/pve missing)." >&2
  exit 1
fi

mkdir -p "$IFACES_D"

IFACE_CONTENT=$(cat <<EOF
# kube_lab NAT bridge for non-k3s / NFS VMs (managed by setup-lab-bridge.sh)
auto ${BRIDGE}
iface ${BRIDGE} inet static
	address ${BRIDGE_CIDR}
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up ${NAT_SCRIPT} up
	post-down ${NAT_SCRIPT} down
EOF
)

if [[ -f "$IFACE_FILE" ]] && grep -qF "address ${BRIDGE_CIDR}" "$IFACE_FILE" && grep -qF "${NAT_SCRIPT}" "$IFACE_FILE"; then
  echo "==> ${IFACE_FILE} already matches; leaving as-is"
else
  if [[ -f "$IFACE_FILE" ]]; then
    echo "==> Updating ${IFACE_FILE} (previous content differed)"
  else
    echo "==> Writing ${IFACE_FILE}"
  fi
  printf '%s\n' "$IFACE_CONTENT" >"$IFACE_FILE"
fi

# Ensure main interfaces file sources interfaces.d (Proxmox uses source .../*).
if [[ -f /etc/network/interfaces ]]; then
  if ! grep -qE '^\s*source(-directory)?\s+/etc/network/interfaces\.d' /etc/network/interfaces; then
    echo "==> Appending source ${IFACES_D}/* to /etc/network/interfaces"
    printf '\nsource %s/*\n' "$IFACES_D" >>/etc/network/interfaces
  fi
fi

# Drop a common leftover address if present on an older lab vmbr1.
if ip link show "$BRIDGE" &>/dev/null; then
  ip addr del 192.168.100.1/24 dev "$BRIDGE" 2>/dev/null || true
  ip addr del 192.168.100.1/32 dev "$BRIDGE" 2>/dev/null || true
fi

echo "==> Enabling IPv4 forwarding (${SYSCTL_FILE})"
cat >"$SYSCTL_FILE" <<EOF
# kube_lab: forward between ${WAN_IFACE} (LAN) and ${BRIDGE} (lab NAT)
net.ipv4.ip_forward=1
EOF
sysctl -p "$SYSCTL_FILE" >/dev/null

echo "==> Installing ${NAT_SCRIPT}"
cat >"$NAT_SCRIPT" <<EOF
#!/usr/bin/env bash
# Idempotent iptables rules for kube_lab NAT bridge (${BRIDGE}).
set -euo pipefail

LAB_NET="${LAB_NET}"
WAN_IFACE="${WAN_IFACE}"
BRIDGE="${BRIDGE}"
COMMENT="kube-lab-nat"

iptables_has() {
  iptables -C "\$@" 2>/dev/null
}

add_once() {
  iptables_has "\$@" || iptables -I "\$@"
}

del_quiet() {
  while iptables_has "\$@"; do
    iptables -D "\$@" || true
  done
}

case "\${1:-up}" in
  up)
    add_once FORWARD -i "\${BRIDGE}" -o "\${WAN_IFACE}" -j ACCEPT -m comment --comment "\${COMMENT}"
    add_once FORWARD -i "\${WAN_IFACE}" -o "\${BRIDGE}" -j ACCEPT -m comment --comment "\${COMMENT}"
    add_once POSTROUTING -t nat -s "\${LAB_NET}" -o "\${WAN_IFACE}" -j MASQUERADE -m comment --comment "\${COMMENT}"
    ;;
  down)
    del_quiet FORWARD -i "\${BRIDGE}" -o "\${WAN_IFACE}" -j ACCEPT -m comment --comment "\${COMMENT}"
    del_quiet FORWARD -i "\${WAN_IFACE}" -o "\${BRIDGE}" -j ACCEPT -m comment --comment "\${COMMENT}"
    del_quiet POSTROUTING -t nat -s "\${LAB_NET}" -o "\${WAN_IFACE}" -j MASQUERADE -m comment --comment "\${COMMENT}"
    ;;
  *)
    echo "Usage: \$0 {up|down}" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$NAT_SCRIPT"

echo "==> Installing if-up hook ${IFUP_HOOK}"
cat >"$IFUP_HOOK" <<EOF
#!/bin/sh
# Re-apply kube_lab NAT rules whenever ${WAN_IFACE} or ${BRIDGE} comes up.
case "\$IFACE" in
  ${WAN_IFACE}|${BRIDGE})
    ${NAT_SCRIPT} up
    ;;
esac
EOF
chmod 755 "$IFUP_HOOK"

echo "==> Bringing up ${BRIDGE}"
if ip link show "$BRIDGE" &>/dev/null; then
  ifup "$BRIDGE" 2>/dev/null || true
  ip addr replace "${BRIDGE_CIDR}" dev "$BRIDGE"
  ip link set "$BRIDGE" up
else
  if ifup "$BRIDGE" 2>/dev/null; then
    :
  else
    ip link add name "$BRIDGE" type bridge
    ip addr add "${BRIDGE_CIDR}" dev "$BRIDGE" || ip addr replace "${BRIDGE_CIDR}" dev "$BRIDGE"
    ip link set "$BRIDGE" up
  fi
fi

"$NAT_SCRIPT" up

echo "==> Done."
echo "    Bridge:  ${BRIDGE} ${BRIDGE_CIDR}"
echo "    Lab net: ${LAB_NET} (MASQUERADE out ${WAN_IFACE})"
echo "    Verify:  ip addr show ${BRIDGE}; iptables -t nat -S | grep kube-lab"
echo "    Next:    point nfs-01 at ${BRIDGE} (see docs/lab-network.md)"
