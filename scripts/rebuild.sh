#!/usr/bin/env bash
# Rebuild the entire home lab: Terraform apply → wait for SSH → Ansible site + verify.
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
ANSIBLE_DIR="$ROOT_DIR/ansible"
INVENTORY="$ANSIBLE_DIR/inventory/hosts.proxmox.yml"

log() { printf '\n==> %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd terraform
require_cmd ansible-playbook
require_cmd ssh

export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"

if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
  echo "Create $TF_DIR/terraform.tfvars from terraform.tfvars.example first." >&2
  exit 1
fi

log "Terraform init"
terraform -chdir="$TF_DIR" init -upgrade

log "Terraform apply"
terraform -chdir="$TF_DIR" apply -auto-approve

if [[ ! -f "$INVENTORY" ]]; then
  echo "Expected generated inventory at $INVENTORY" >&2
  exit 1
fi

# Prefer yq if present; fall back to scanning inventory for ansible_host lines.
if command -v yq >/dev/null 2>&1; then
  HOSTS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && HOSTS+=("$line")
  done < <(yq -r '.. | select(has("ansible_host")) | .ansible_host' "$INVENTORY")
else
  HOSTS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && HOSTS+=("$line")
  done < <(grep -Eo 'ansible_host: [^[:space:]]+' "$INVENTORY" | awk '{print $2}' | tr -d '"')
fi

SSH_USER="${ANSIBLE_USER:-ubuntu}"

log "Waiting for SSH on ${#HOSTS[@]} hosts"
for host in "${HOSTS[@]}"; do
  echo -n "  $host"
  for _ in $(seq 1 60); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${SSH_USER}@${host}" true 2>/dev/null; then
      echo " ready"
      break
    fi
    echo -n "."
    sleep 5
  done
done

log "Install Ansible collections"
ansible-galaxy collection install -r "$ANSIBLE_DIR/requirements.yml"

log "Configure cluster with Ansible"
ansible-playbook -i "$INVENTORY" "$ANSIBLE_DIR/playbooks/site.yml"

log "Verify cluster"
ansible-playbook -i "$INVENTORY" "$ANSIBLE_DIR/playbooks/verify.yml"

log "Done. Use: export KUBECONFIG=$ROOT_DIR/kubeconfig && kubectl get nodes"