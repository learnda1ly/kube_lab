# kube_lab

Rebuildable Kubernetes home lab on **Proxmox**, provisioned with **Terraform** and configured with **Ansible** (**k3s** + dedicated **NFS** for persistent volumes).

```text
terraform apply  →  Proxmox VMs (k3s + nfs-01) + generated inventory
ansible site.yml →  base OS + NFS export + k3s + StorageClass "nfs"
```

Full walkthrough: **[docs/overview.md](docs/overview.md)**.

## Layout

| Path | Purpose |
|------|---------|
| `terraform/` | Proxmox VMs (control plane, workers, NFS), writes Ansible inventory |
| `ansible/` | OS prep, NFS server, k3s install/join, NFS provisioner |
| `manifests/storage/` | PVC smoke test only; provisioner is Ansible-owned |
| `scripts/rebuild.sh` | End-to-end recreate |
| `scripts/create-ubuntu-template.sh` | One-time Ubuntu cloud-init template on Proxmox |
| `docs/overview.md` | Project map, config locations, day-2 commands |
| `docs/terraform.md` | How Terraform provisions VMs and Ansible inventory |
| `docs/ansible.md` | Inventory groups, playbooks, roles, variables |
| `docs/operations.md` | Scale, upgrade, destroy, networking, troubleshooting |
| `docs/proxmox-template.md` | One-time cloud-init template setup |
| `docs/nfs-storage.md` | NFS VM + dynamic PVCs for Splunk/apps |
| `docs/TODO.md` | Known overcomplications / cleanup list |

## Prerequisites

- Proxmox VE with a cloud-init Ubuntu template ([docs/proxmox-template.md](docs/proxmox-template.md))
- Terraform `>= 1.5`
- Ansible `>= 2.15` + collections in `ansible/requirements.yml`
- SSH key authorized on the template via `ssh_public_keys`
- Proxmox API token (`PROXMOX_VE_API_TOKEN`)

## One-time setup

```bash
cp .env.example .env
# edit .env: PROXMOX_VE_API_TOKEN + ANSIBLE_PRIVATE_KEY_FILE

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit IPs, node name, template_id, SSH keys, gateway, nfs_server

# One-time Proxmox template (if needed): see docs/proxmox-template.md
# or scripts/create-ubuntu-template.sh

make init
```

Makefile day-2 targets (`plan` / `apply` / `ansible` / …) source `.env` when present (same as `scripts/rebuild.sh`).

## Rebuild from scratch

```bash
make rebuild
# or: ./scripts/rebuild.sh
```

That will:

1. `terraform apply` — create/update VMs (including `nfs-01`) and generate `ansible/inventory/hosts.proxmox.yml`
2. Wait until SSH answers on each node
3. Run `ansible/playbooks/site.yml` (common + NFS + k3s + NFS StorageClass)
4. Run `ansible/playbooks/verify.yml`

Then:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
kubectl get storageclass
```

## Day-2 commands

```bash
make plan       # preview infra changes
make apply      # infra only
make ansible    # config only (inventory must exist)
make storage    # re-apply NFS provisioner / StorageClass only
make verify     # readiness check (nodes + NFS export)
make destroy    # tear down VMs (typed confirmation)
```

## Cluster shape (defaults)

- 1× control plane — `192.168.1.20` (edit in tfvars)
- 2× workers — `.21` / `.22`
- 1× NFS server — `nfs-01` at `192.168.1.30`, export `/srv/nfs/k3s`
- k3s with Traefik disabled (`--disable traefik`) so you can add your own ingress later
- StorageClass `nfs` via nfs-subdir-external-provisioner (see [docs/nfs-storage.md](docs/nfs-storage.md))

Adjust CPU/RAM/disk/IPs in `terraform/terraform.tfvars`; Terraform regenerates inventory so Ansible stays in sync.

Deep dives: [docs/terraform.md](docs/terraform.md) · [docs/ansible.md](docs/ansible.md) · [docs/operations.md](docs/operations.md) · [docs/nfs-storage.md](docs/nfs-storage.md)

## Secrets

Do not commit:

- `.env`
- `terraform/terraform.tfvars`
- `kubeconfig`
- API tokens / private keys

Only `*.example` files are tracked.
