# kube_lab

Rebuildable Kubernetes home lab on **Proxmox**, provisioned with **Terraform** and configured with **Ansible** (**k3s** + dedicated **NFS** for persistent volumes).

```text
terraform apply  →  Proxmox VMs (k3s + nfs-01) + generated inventory
ansible site.yml →  base OS + NFS export + k3s + StorageClass "nfs"
```

Full walkthrough: **[docs/overview.md](docs/overview.md)**.  
Agent / successor brief (every requirement addressed + quality bar): **[instructions.md](instructions.md)**.

## Layout

| Path | Purpose |
|------|---------|
| `instructions.md` | Contract for the next agent: requirements, pitfalls, do-not-regress, improvement bar |
| `ansible/` | OS prep, NFS server, k3s install/join, NFS provisioner |
| `manifests/storage/` | PVC smoke test only; provisioner is Ansible-owned |
| `manifests/splunk/` | Standalone Splunk on NFS (`storageClassName: nfs`) |
| `scripts/rebuild.sh` | End-to-end recreate |
| `scripts/create-ubuntu-template.sh` | One-time Ubuntu cloud-init template on Proxmox |
| `docs/overview.md` | Project map, config locations, day-2 commands |
| `docs/terraform.md` | How Terraform provisions VMs and Ansible inventory |
| `docs/ansible.md` | Inventory groups, playbooks, roles, variables |
| `docs/operations.md` | Scale, upgrade, destroy, networking, troubleshooting |
| `docs/proxmox-template.md` | One-time cloud-init template setup |
| `docs/nfs-storage.md` | NFS VM + dynamic PVCs for Splunk/apps |
| `docs/lab-network.md` | Proxmox `vmbr1` NAT lab net (non-k3s / NFS) |
| `docs/rhel9-uf.md` | Separate RHEL 9 VMs for Splunk UF install/upgrade tests |
| `docs/zero-trust.md` | DoD Zero Trust pillar recommendations for this lab |
| `docs/TODO.md` | Known overcomplications / cleanup list |
| `terraform/rhel9/` | Independent Terraform root: 3× RHEL 9 UF test VMs (not k3s) |

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

### RHEL 9 Splunk UF lab (independent of k3s)

See **[docs/rhel9-uf.md](docs/rhel9-uf.md)**. Separate Terraform root and inventory — does not use `make apply` / `hosts.proxmox.yml`.

```bash
cp terraform/rhel9/terraform.tfvars.example terraform/rhel9/terraform.tfvars
# edit: RHEL 9 template_id, ssh keys, IPs

make rhel9-init
make rhel9-apply
make rhel9-ansible
make rhel9-destroy   # k3s untouched
```

## Cluster shape (defaults)

- 1× control plane — `192.168.1.20` on LAN `vmbr0` (edit in tfvars)
- 2× workers — `.21` / `.22` on LAN `vmbr0`
- 1× NFS server — `nfs-01` at `10.10.10.30` on lab `vmbr1` (NAT; see [docs/lab-network.md](docs/lab-network.md))
- k3s with Traefik disabled (`--disable traefik`) so you can add your own ingress later
- StorageClass `nfs` via nfs-subdir-external-provisioner (see [docs/nfs-storage.md](docs/nfs-storage.md))

One-time on Proxmox before first NFS-on-lab apply: `scripts/setup-lab-bridge.sh`. Operator laptop needs a static route to `10.10.10.0/24` via the Proxmox LAN IP.

Adjust CPU/RAM/disk/IPs in `terraform/terraform.tfvars`; Terraform regenerates inventory so Ansible stays in sync.

Deep dives: [docs/terraform.md](docs/terraform.md) · [docs/ansible.md](docs/ansible.md) · [docs/operations.md](docs/operations.md) · [docs/nfs-storage.md](docs/nfs-storage.md)

## Secrets

Do not commit:

- `.env`
- `terraform/terraform.tfvars`
- `kubeconfig`
- API tokens / private keys

Only `*.example` files are tracked.
