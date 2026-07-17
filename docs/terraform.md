# Terraform for kube_lab

How the Terraform layer works: what it owns, how the files fit together, and how it hands off to Ansible.

## Big picture

Terraform is **layer 1 of a two-layer lab**. It only owns **infrastructure on Proxmox**:

1. Clone a cloud-init Ubuntu template into VMs
2. Size them (CPU/RAM/disk), give them static IPs, inject SSH keys
3. Write an Ansible inventory that matches those VMs

It does **not** install k3s, configure NFS exports, or create StorageClasses. That is Ansible’s job after Terraform finishes.

```text
You (tfvars + API token)
        │
        ▼
terraform apply
        │
        ├──► Proxmox VMs: k3s-cp-01, k3s-wk-*, nfs-01
        └──► ansible/inventory/hosts.proxmox.yml
                    │
                    ▼
            ansible site.yml  (OS + NFS + k3s + provisioner)
```

| Layer | Answers |
|-------|---------|
| Terraform | What machines exist, with what IPs and sizes? |
| Ansible | What software runs on them? |

Related docs:

- [overview.md](overview.md) — full project map
- [ansible.md](ansible.md) — configuration layer after apply
- [operations.md](operations.md) — day-2 scale, upgrade, troubleshooting
- [proxmox-template.md](proxmox-template.md) — one-time Ubuntu cloud-init template
- [nfs-storage.md](nfs-storage.md) — NFS VM + StorageClass after Ansible runs
- [TODO.md](TODO.md) — known overcomplications / deferred cleanups

## File layout

Everything lives under `terraform/`:

| File | Role |
|------|------|
| `versions.tf` | Terraform version + provider pins |
| `providers.tf` | How to talk to Proxmox |
| `variables.tf` | Inputs (types, defaults, descriptions) |
| `terraform.tfvars` | **Your** real values (gitignored; copy from `.example`) |
| `terraform.tfvars.example` | Tracked template for local tfvars |
| `main.tf` | Resources: VMs + inventory file |
| `outputs.tf` | Useful values after apply |
| `.terraform.lock.hcl` | Locked provider checksums (committed) |

There is **no remote backend** configured. State is local: `terraform/terraform.tfstate` on the machine that runs apply. That is fine for a single-operator home lab; do not apply from two machines without sharing state.

## Providers

### `bpg/proxmox` (~> 0.70)

Talks to the Proxmox VE API (and sometimes SSH to the node). Configured in `providers.tf`:

- `endpoint` — `https://your-pve:8006/`
- `api_token` — usually left `null` in tfvars so the secret comes from `PROXMOX_VE_API_TOKEN`
- `insecure = true` — typical for home-lab self-signed certs
- `ssh { agent = true }` — some provider operations need SSH to the Proxmox host as `root` (or `proxmox_ssh_username`); your local SSH agent must already have a key that can log in

### `hashicorp/local`

Writes a file on the machine running Terraform: the Ansible inventory. No cloud API involved.

## Configuration: variables vs secrets

### Variables (`variables.tf`)

These define the schema of the lab:

- **Proxmox placement** — node name, datastores, cluster `bridge` / optional VLAN
- **Identity** — SSH user + public keys for cloud-init
- **Cluster network** — gateway, DNS for k3s on the LAN
- **Lab network** — `lab_network` (bridge/gateway/DNS for non-k3s), `lab_cidr`, `proxmox_lan_ip`
- **Cluster shape** — one `control_plane` object + a list of `workers`
- **NFS VM** — separate object on `lab_network` + export path / client CIDR for Ansible vars

Each node object looks like:

```hcl
{
  name    = "k3s-cp-01"
  vmid    = 200          # Proxmox VMID (must be unique on the cluster)
  cores   = 2
  memory  = 4096         # MiB
  disk_gb = 40
  ip      = "192.168.1.20"
  cidr    = 24           # becomes 192.168.1.20/24 in cloud-init
}
```

Defaults in `variables.tf` match the README topology (`.20` CP, `.21`/`.22` workers, NFS at `10.10.10.30` on `vmbr1`). Override what you need in `terraform.tfvars`. Create the lab bridge once with [lab-network.md](lab-network.md) / `scripts/setup-lab-bridge.sh` before applying NFS on `vmbr1`.

### Secrets

- Prefer **env** / `.env`: `PROXMOX_VE_API_TOKEN='user@pam!token=...'` (Makefile and scripts source `.env` when present)
- Endpoint and `proxmox_insecure` come from **tfvars**, not from `.env`
- SSH *public* keys go in tfvars; Ansible uses `ANSIBLE_PRIVATE_KEY_FILE` from `.env` for the matching private key

See also [API token notes](proxmox-template.md#api-token).

## Prerequisite: the cloud-init template

Terraform **clones** an existing Proxmox template (`template_id`, e.g. `9000`). Build that once — see [proxmox-template.md](proxmox-template.md).

Also required:

| Variable | Purpose |
|----------|---------|
| `vm_datastore` | Where VM disks live (often `local-lvm`) |
| `snippet_datastore` | Cloud-init **drive** datastore; must allow content-type **images** (default `local-lvm`). The variable name is historical — this is not Proxmox “Snippets” content. |

If that datastore lacks **images**, apply fails when attaching the cloud-init drive.

## How `main.tf` builds the cluster

### Normalize nodes with a local

```hcl
locals {
  nodes = concat(
    [merge(var.control_plane, { role = "control_plane" })],
    [for w in var.workers : merge(w, { role = "worker" })]
  )
}
```

`local.nodes` is one list: control plane + every worker, each tagged with `role`. That list drives:

- the `for_each` on k3s VMs
- inventory host groups
- outputs like `control_plane_ips` / `worker_ips`

NFS is **not** in this list — it is a separate resource so it never gets k3s roles by accident.

### One resource, many VMs (`for_each`)

```hcl
resource "proxmox_virtual_environment_vm" "node" {
  for_each = { for n in local.nodes : n.name => n }
  ...
}
```

`for_each` keyed by name means:

| Change in tfvars | Terraform effect |
|------------------|------------------|
| Add a worker | Create one new VM |
| Remove a worker | Destroy that VM (destructive; care with disk data) |
| Rename a host | Destroy + create under the new key |

Per VM:

| Block | Meaning |
|-------|---------|
| `cpu { type = "host" }` | Pass-through host CPU model |
| `memory.dedicated` | Fixed RAM from tfvars |
| `disk` | Full clone disk size; `raw` + `discard` on chosen datastore |
| `clone { vm_id, full = true }` | Full clone of template (not linked clone) |
| `network_device` | virtio on `bridge`, optional `vlan_id` |
| `initialization` | cloud-init: static IP, gateway, DNS, user + SSH keys |
| `operating_system.type = "l26"` | Linux 2.6+ guest type for Proxmox |
| `stop_on_destroy = true` | Graceful stop before destroy |

**QEMU guest agent on k3s nodes is deliberately off.** With PVE 9 + `bpg/proxmox`, `agent = true` can hang refresh/import waiting for guest IPs. IPs are still known because they are set in tfvars; Terraform does not need the agent to discover them. The guest can still run the agent package; the Proxmox resource just does not wait on it.

**`lifecycle { ignore_changes = [clone] }`:** if a VM was imported or previously created without going through clone in state, Terraform would otherwise want to replace it whenever `clone` differs. Ignoring clone keeps day-2 plans from needlessly recreating nodes.

### Dedicated NFS VM

`proxmox_virtual_environment_vm.nfs` is almost the same shape, but:

- Uses `var.nfs_server.*` instead of the node list
- Attaches to **`lab_network`** (`vmbr1` by default), not the cluster `bridge`
- Tags: `cluster_name` + `"nfs"` (no k3s role)
- Typically larger disk (default 200 GiB) and less RAM
- `agent { enabled = false }` — same PVE 9 hang workaround as k3s nodes

Terraform still does **not** install `nfs-kernel-server`. It only creates the empty Ubuntu VM and puts NFS path/CIDR into inventory vars for Ansible. Details: [nfs-storage.md](nfs-storage.md) · [lab-network.md](lab-network.md).

### Generate Ansible inventory (the glue)

```hcl
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.proxmox.yml"
  content  = yamlencode({ ... })
}
```

After every successful apply that touches this resource, inventory looks like:

```yaml
all:
  children:
    k3s_cluster:
      children:
        control_plane:
          hosts:
            k3s-cp-01:
              ansible_host: 192.168.1.20
              ansible_user: ubuntu
        workers:
          hosts:
            k3s-wk-01:
              ansible_host: 192.168.1.21
              ansible_user: ubuntu
            k3s-wk-02:
              ansible_host: 192.168.1.22
              ansible_user: ubuntu
      vars:
        lab_cidr: 10.10.10.0/24
        proxmox_lan_ip: 192.168.1.228
    nfs:
      hosts:
        nfs-01:
          ansible_host: 10.10.10.30
          ansible_user: ubuntu
      vars:
        nfs_export_path: /srv/nfs/k3s
        nfs_client_cidr: 192.168.1.0/24
```

That file is **generated**, not hand-edited. Change an IP in tfvars → apply → inventory updates → Ansible targets the new truth. That is the main design win of this Terraform setup.

## Outputs

After apply, `terraform output` exposes:

| Output | Meaning |
|--------|---------|
| `control_plane_ips` | Control-plane IPv4 addresses |
| `worker_ips` | Worker IPv4 addresses |
| `nfs_server_ip` | NFS server IPv4 (on lab network) |
| `lab_cidr` | Lab / storage CIDR |
| `lab_bridge` | Proxmox bridge for non-k3s VMs |
| `nfs_export_path` | Export path on the NFS VM |
| `ansible_inventory_path` | Path to generated inventory |
| `vm_ids` | Map of name → Proxmox VMID (k3s nodes + NFS) |

Useful for scripts and for humans (`terraform output nfs_server_ip`).

## Commands (Makefile wrappers)

| Command | What it does |
|---------|----------------|
| `make init` | `terraform init -upgrade` + Ansible Galaxy (sources `.env`) |
| `make plan` | Show what would change (sources `.env`) |
| `make apply` | Interactive apply: VMs + inventory (sources `.env`) |
| `make rebuild` | `scripts/rebuild.sh`: init → apply → wait for SSH → site → verify |
| `make destroy` | `scripts/destroy.sh`: destroy all managed VMs (confirmation) |

Day-2 ops (scale, upgrade, troubleshooting): [operations.md](operations.md).

### Day-2 patterns

- Change CPU/RAM/disk/IP in tfvars → `make plan` → `make apply` → usually re-run Ansible if OS/config must catch up
- Scale workers: add/remove entries in the `workers` list → apply (removing destroys that VM)
- Infra-only vs config-only: `make apply` vs `make ansible`

## First `apply` sequence

1. Provider authenticates to Proxmox with the token
2. For each k3s node + NFS: full-clone template → set CPU/RAM/disk → attach NIC → write cloud-init (IP, user, keys) → start VM
3. Cloud-init inside the guest applies network + SSH user
4. `local_file` writes `hosts.proxmox.yml`
5. State file records VM IDs and attributes so the next plan is a diff, not a recreate

Then (outside Terraform) rebuild waits for SSH and Ansible takes over.

## State

Terraform’s state says: these Proxmox VMIDs and this inventory file are managed by this config.

| Situation | Implication |
|-----------|-------------|
| Drift (someone edits a VM in the Proxmox UI) | Next `plan` may show diffs or want to change it back |
| Destroy | `scripts/destroy.sh` destroys the VMs and also deletes local `kubeconfig` plus the generated inventory file |
| One local state file | Treat the machine that holds `terraform.tfstate` as the control plane for infra changes, or introduce a remote backend later |

## Design choices

1. **Declarative topology in tfvars** — cluster shape is data, not copy-pasted Proxmox UI clicks.
2. **Inventory as a Terraform product** — prevents Ansible still pointing at old IPs.
3. **NFS is a VM, not Proxmox storage** — storage is rebuildable the same way as compute.
4. **Split responsibility** — Terraform = empty machines + network identity; Ansible = roles. Keeps the Terraform graph small and rebuildable.
5. **Practical Proxmox quirks** — guest agent disabled on VM resources (k3s + NFS); `ignore_changes` on clone; cloud-init drive datastore must support **images**.

## Decision guide when changing something

Ask three questions:

1. **Does this change which VMs exist or their hardware/network?** → Terraform / tfvars
2. **Does this change software or exports on those VMs?** → Ansible
3. **Did I change IPs or hostnames?** → Apply Terraform first (inventory), then Ansible
