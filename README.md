# kube_lab

Rebuildable Kubernetes home lab on **Proxmox**, provisioned with **Terraform** and configured with **Ansible** (**k3s**).

```text
terraform apply  →  Proxmox VMs + generated inventory
ansible site.yml →  base OS hardening bits + k3s cluster
```

## Layout

| Path | Purpose |
|------|---------|
| `terraform/` | Proxmox VMs (control plane + workers), writes Ansible inventory |
| `ansible/` | OS prep + k3s install/join |
| `scripts/rebuild.sh` | End-to-end recreate |
| `docs/proxmox-template.md` | One-time cloud-init template setup |
| `docs/openshift-on-proxmox.md` | Design notes: OpenShift/OKD on this stack (incl. air-gap) |

## Prerequisites

- Proxmox VE with a cloud-init Ubuntu template ([docs/proxmox-template.md](docs/proxmox-template.md))
- Terraform `>= 1.5`
- Ansible `>= 2.15` + collections in `ansible/requirements.yml`
- SSH key authorized on the template via `ssh_public_keys`
- Proxmox API token (`PROXMOX_VE_API_TOKEN`)

## One-time setup

```bash
cp .env.example .env
# edit .env with Proxmox endpoint + token

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit IPs, node name, template_id, SSH keys, gateway

make init
```

## Rebuild from scratch

```bash
make rebuild
# or: ./scripts/rebuild.sh
```

That will:

1. `terraform apply` — create/update VMs and generate `ansible/inventory/hosts.proxmox.yml`
2. Wait until SSH answers on each node
3. Run `ansible/playbooks/site.yml` (common + k3s)
4. Run `ansible/playbooks/verify.yml`

Then:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
```

## Day-2 commands

```bash
make plan       # preview infra changes
make apply      # infra only
make ansible    # config only (inventory must exist)
make verify     # readiness check
make destroy    # tear down VMs (typed confirmation)
```

## Cluster shape (defaults)

- 1× control plane — `192.168.1.20` (edit in tfvars)
- 2× workers — `.21` / `.22`
- k3s with Traefik disabled (`--disable traefik`) so you can add your own ingress later

Adjust CPU/RAM/disk/IPs in `terraform/terraform.tfvars`; Terraform regenerates inventory so Ansible stays in sync.

## Secrets

Do not commit:

- `.env`
- `terraform/terraform.tfvars`
- `kubeconfig`
- API tokens / private keys

Only `*.example` files are tracked.