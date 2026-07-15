#!/usr/bin/env bash
# Tear down Proxmox VMs managed by this repo's Terraform state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$ROOT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

TF_DIR="$ROOT_DIR/terraform"

echo "This will destroy all Terraform-managed cluster VMs."
read -r -p "Type 'destroy' to continue: " confirm
[[ "$confirm" == "destroy" ]] || { echo "Aborted."; exit 1; }

terraform -chdir="$TF_DIR" destroy -auto-approve
rm -f "$ROOT_DIR/kubeconfig" "$ROOT_DIR/ansible/inventory/hosts.proxmox.yml"

echo "Destroyed."