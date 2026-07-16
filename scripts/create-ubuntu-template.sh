#!/usr/bin/env bash
# Build Ubuntu 24.04 cloud-init template (default VMID 9000) on Proxmox.
#
# From your Mac (will prompt for sudo password on the Proxmox host):
#   scp -i ~/.ssh/squinlan_ed25519 scripts/create-ubuntu-template.sh squinlan@192.168.1.228:/tmp/
#   ssh -t -i ~/.ssh/squinlan_ed25519 squinlan@192.168.1.228 'sudo bash /tmp/create-ubuntu-template.sh'
set -euo pipefail

VMID="${VMID:-9000}"
NAME="${NAME:-ubuntu-24.04-cloud}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
IMAGE_PATH="/var/tmp/noble-server-cloudimg-amd64.img"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo bash $0)" >&2
  exit 1
fi

if qm status "$VMID" &>/dev/null; then
  echo "VMID $VMID already exists. Aborting."
  exit 1
fi

echo "==> Downloading Ubuntu cloud image"
wget -O "$IMAGE_PATH" "$IMAGE_URL"

echo "==> Creating VM $VMID ($NAME)"
qm create "$VMID" \
  --name "$NAME" \
  --memory 2048 \
  --cores 2 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --agent enabled=1 \
  --ostype l26

echo "==> Importing disk to ${STORAGE}"
qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE"

DISK_REF=$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2; exit}')
if [[ -z "${DISK_REF}" ]]; then
  echo "Could not find imported unused0 disk" >&2
  qm config "$VMID"
  exit 1
fi

qm set "$VMID" --scsi0 "${DISK_REF}"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0
qm set "$VMID" --ipconfig0 ip=dhcp

echo "==> Converting to template"
qm template "$VMID"

rm -f "$IMAGE_PATH"
echo "==> Done. Template VMID=${VMID} ready for Terraform (template_id = ${VMID})."