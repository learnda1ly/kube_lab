#!/usr/bin/env bash
# Build RHEL 9 cloud-init template (default VMID 9001) on a Proxmox host.
#
# Official RHEL cloud images require a Red Hat login. Download the qcow2 once
# from https://access.redhat.com (or Developer) then either:
#
#   A) Copy image to the Proxmox node and set IMAGE_PATH, or
#   B) Place it on this machine and scp it before running on PVE.
#
# Copy to the Proxmox node and run as root, for example:
#   scp /path/to/rhel-9.*-x86_64-kvm.qcow2 user@proxmox:/var/tmp/
#   scp scripts/create-rhel9-template.sh user@proxmox:/tmp/
#   ssh -t user@proxmox 'sudo IMAGE_PATH=/var/tmp/rhel-9.qcow2 bash /tmp/create-rhel9-template.sh'
#
# See docs/rhel9-uf.md.
set -euo pipefail

VMID="${VMID:-9001}"
NAME="${NAME:-rhel-9-cloud}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
# Must point at an already-downloaded RHEL 9 KVM/cloud qcow2 (or raw) image.
IMAGE_PATH="${IMAGE_PATH:-/var/tmp/rhel-9-x86_64-kvm.qcow2}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo bash $0)" >&2
  exit 1
fi

if qm status "$VMID" &>/dev/null; then
  echo "VMID $VMID already exists. Aborting."
  exit 1
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
  cat >&2 <<EOF
RHEL cloud image not found at: $IMAGE_PATH

Official RHEL 9 KVM guest images are not publicly wget-able — download from
Red Hat (Developer subscription is fine for a home lab), copy to the Proxmox
host, then re-run with:

  sudo IMAGE_PATH=/var/tmp/<your-rhel9>.qcow2 bash $0
EOF
  exit 1
fi

echo "==> Creating VM $VMID ($NAME) from $IMAGE_PATH"
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
# Match official RHEL cloud default; Terraform also injects ssh_user=cloud-user
qm set "$VMID" --ciuser cloud-user

echo "==> Converting to template"
qm template "$VMID"

echo "==> Done. Template VMID=${VMID} ready for Terraform (terraform/rhel9 template_id = ${VMID})."
echo "    Keep the qcow2 if you want; Terraform clones do not need it."
