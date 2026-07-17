# Project overview

Rebuildable Kubernetes home lab on **Proxmox**: Terraform creates VMs and Ansible inventory; Ansible configures the OS, NFS, k3s, and an NFS StorageClass.

```text
.env + terraform.tfvars
        │
        ▼
terraform apply
        │
        ├──► Proxmox VMs: control plane, workers, nfs-01
        └──► ansible/inventory/hosts.proxmox.yml   (generated, gitignored)
                    │
                    ▼
            ansible playbooks/site.yml
                    │
                    ├── common          (all k3s nodes + NFS VM)
                    ├── nfs_server      (nfs group)
                    ├── k3s             (server then agents)
                    └── nfs_provisioner (HelmChart → StorageClass "nfs")
                    │
                    ▼
            kubeconfig (repo root) + verify.yml
```

## What each layer owns

| Layer | Owns | Does not own |
|-------|------|--------------|
| **Terraform** | Proxmox VMs, static IPs, SSH keys via cloud-init, generated inventory | Packages, k3s, NFS export, Kubernetes objects |
| **Ansible** | OS prep, NFS server, k3s install/join, StorageClass provisioner, kubeconfig fetch | Creating VMs or assigning IPs |
| **Manifests** | PVC smoke (`manifests/storage/`) + apps (e.g. `manifests/splunk/`) | Provisioner install (Ansible owns that) |
| **Scripts / Make** | Orchestration: init, plan, apply, rebuild, destroy | Cluster semantics |

## Repository map

| Path | Purpose |
|------|---------|
| `terraform/` | Proxmox provider config, VM resources, inventory generator |
| `ansible/` | Playbooks, roles, inventory `group_vars`, `ansible.cfg`, Galaxy requirements |
| `ansible/inventory/hosts.proxmox.yml` | **Generated** by Terraform — never hand-edit |
| `manifests/storage/` | PVC smoke test only (see README there) |
| `manifests/splunk/` | Standalone Splunk on NFS StorageClass |
| `scripts/rebuild.sh` | Full recreate: apply → SSH wait → site → verify |
| `scripts/destroy.sh` | Destroy VMs; remove kubeconfig + inventory |
| `scripts/create-ubuntu-template.sh` | One-time Proxmox template helper |
| `scripts/setup-lab-bridge.sh` | One-time Proxmox `vmbr1` NAT lab bridge |
| `docs/` | Layer guides and this overview |
| `.env` | API token + Ansible SSH settings; sourced by Makefile and scripts |
| `kubeconfig` | Fetched to repo root by the k3s role (gitignored) |

## Documentation index

| Doc | Topic |
|-----|--------|
| [../instructions.md](../instructions.md) | **Agent brief** — all addressed requirements, pitfalls, improvement bar |
| [terraform.md](terraform.md) | Providers, variables, VM resources, inventory glue |
| [ansible.md](ansible.md) | Inventory groups, playbooks, roles, variables, verify |
| [operations.md](operations.md) | Day-2: scale, upgrade, destroy, networking, troubleshooting |
| [proxmox-template.md](proxmox-template.md) | One-time Ubuntu cloud-init template + API token |
| [nfs-storage.md](nfs-storage.md) | NFS VM, export, StorageClass, smoke PVC |
| [lab-network.md](lab-network.md) | Proxmox `vmbr1` NAT lab net for non-k3s / NFS |
| [zero-trust.md](zero-trust.md) | DoD ZT pillar recommendations for this lab |
| [TODO.md](TODO.md) | Known overcomplications and cleanup ideas |

## Prerequisites

- Proxmox VE with a cloud-init Ubuntu template ([proxmox-template.md](proxmox-template.md))
- Terraform `>= 1.5`
- Ansible `>= 2.15` + collections in `ansible/requirements.yml`
- SSH key in `ssh_public_keys` (tfvars) and available to your agent for Ansible
- Proxmox API token as `PROXMOX_VE_API_TOKEN`

## Configuration: what goes where

| Setting | Where | Notes |
|---------|--------|------|
| Proxmox API token | `.env` → `PROXMOX_VE_API_TOKEN` | Preferred over tfvars |
| Ansible SSH key / user | `.env` → `ANSIBLE_PRIVATE_KEY_FILE`, `ANSIBLE_USER` | Sourced by Makefile |
| Proxmox endpoint, node, IPs, sizes | `terraform/terraform.tfvars` | Required for apply |
| SSH user / public keys | tfvars (`ssh_user`, `ssh_public_keys`) | Must match Ansible SSH |
| k3s version + Traefik-off | `ansible/roles/k3s/defaults/main.yml` | Override via inventory group_vars if needed |
| timezone / packages | `ansible/inventory/group_vars/all/main.yml` | Loaded next to the inventory file |
| NFS path / client CIDR | tfvars → inventory `nfs` group vars | Ansible roles require these from inventory |

Only `PROXMOX_VE_API_TOKEN` is read by the Terraform provider (when `proxmox_api_token` is null). Endpoint and insecure TLS come from **tfvars**.

## Day-0 → day-2 commands

```bash
# One-time
cp .env.example .env                       # token + Ansible SSH key path
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
make init

# Full lab
make rebuild                               # or ./scripts/rebuild.sh

# Day-2 (Makefile sources .env when present)
make plan
make apply                                 # infra + regenerate inventory
make ansible                               # full site.yml
make storage                               # NFS StorageClass only
make verify
make destroy                               # typed confirmation
```

After bring-up:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
kubectl get storageclass
```

## Default cluster shape

| Role | Name (default) | IP (default) | Network |
|------|----------------|--------------|---------|
| Control plane | `k3s-cp-01` | `192.168.1.20` | LAN `vmbr0` |
| Workers | `k3s-wk-01`, `k3s-wk-02` | `.21`, `.22` | LAN `vmbr0` |
| NFS | `nfs-01` | `10.10.10.30` | lab `vmbr1` (NAT) |

- k3s with Traefik disabled (`--disable traefik`)
- StorageClass `nfs` via nfs-subdir-external-provisioner (not the cluster default; `local-path` remains)
- NFS export `/srv/nfs/k3s` limited to the **k3s LAN** CIDR (`nfs_client_cidr`); k3s nodes reach NFS via a static route through Proxmox ([lab-network.md](lab-network.md))

## Secrets (do not commit)

- `.env`
- `terraform/terraform.tfvars`
- `kubeconfig`
- API tokens / private keys

Only `*.example` files are tracked.

## Design principles

1. **Rebuildable** — wipe VMs, re-apply Terraform + Ansible, get the same shape.
2. **Inventory is generated** — Ansible never drifts from Terraform IPs/hostnames if you re-apply.
3. **Split responsibility** — infra vs config stay separate so each graph stays small.
4. **NFS is a VM** — not Proxmox shared storage; same lifecycle as the cluster.

## Documentation maintenance

When behavior changes, update the matching layer doc and [operations.md](operations.md) if day-2 steps change. [TODO.md](TODO.md) tracks deferred cleanups, not user-facing how-to.

## When something breaks

Short map (full runbook: [operations.md](operations.md)):

| Symptom | Likely layer |
|---------|----------------|
| VM missing / wrong IP / wrong size | Terraform / tfvars |
| SSH timeout after apply | cloud-init, keys, network, or wait longer |
| Packages / timezone / swap | `common` role |
| NFS export missing | `nfs_server` + inventory `nfs_*` vars |
| Nodes NotReady / no kubeconfig | `k3s` role |
| No StorageClass `nfs` | `nfs_provisioner` / `make storage` |
| Inventory missing | Run `make apply` (or rebuild); do not invent hosts by hand |
