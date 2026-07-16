# Operations runbook

Day-2 workflows, networking expectations, destroy/rebuild behavior, and troubleshooting. Assumes you already completed one-time setup in [overview.md](overview.md).

Related: [terraform.md](terraform.md) · [ansible.md](ansible.md) · [nfs-storage.md](nfs-storage.md)

## Environment and SSH

### `.env` (gitignored)

Copy from `.env.example`. Makefile targets and `scripts/*.sh` source it when present:

| Variable | Used by | Purpose |
|----------|---------|---------|
| `PROXMOX_VE_API_TOKEN` | Terraform provider | Auth when `proxmox_api_token` is null in tfvars |
| `ANSIBLE_USER` | Ansible + rebuild SSH wait | Must match tfvars `ssh_user` (default `ubuntu`) |
| `ANSIBLE_PRIVATE_KEY_FILE` | Ansible | Private key matching a public key in tfvars `ssh_public_keys` |

**Not** in `.env`: Proxmox endpoint and TLS insecure flag — those are tfvars (`proxmox_endpoint`, `proxmox_insecure`).

### Two different SSH consumers

| Consumer | How it authenticates |
|----------|----------------------|
| Terraform → Proxmox **node** | Provider `ssh { agent = true }` as `proxmox_ssh_username` (often `root`) for some API/SSH ops |
| Ansible → **guest** VMs | `ANSIBLE_USER` + `ANSIBLE_PRIVATE_KEY_FILE` (or your default SSH identity if unset) |
| `rebuild.sh` SSH wait | `ssh ${ANSIBLE_USER}@host` using your normal SSH agent / `~/.ssh` defaults — it does **not** pass `ANSIBLE_PRIVATE_KEY_FILE` |

If rebuild hangs on “Waiting for SSH” but `make ansible` works, fix agent/default key for bare `ssh`, or add an `IdentityFile` in `~/.ssh/config` for the lab subnet.

### Quick connectivity check

```bash
# After apply / inventory exists
source .env
ssh -i "$ANSIBLE_PRIVATE_KEY_FILE" "${ANSIBLE_USER}@192.168.1.20" true
```

## Networking expectations

Defaults assume a flat LAN (edit in tfvars):

| Item | Default |
|------|---------|
| Gateway | `192.168.1.1` |
| Node CIDR | `/24` |
| DNS | from `dns_servers` in tfvars |
| Bridge | `vmbr0` (optional `vlan_id`) |
| NFS client allowlist | `nfs_client_cidr` (must include all k3s node IPs) |

Ports that must be open between lab machines (typical home LAN = all open):

| From → to | Port / proto | Why |
|-----------|--------------|-----|
| Your laptop → guests | TCP 22 | Ansible / SSH |
| Your laptop → control plane | TCP 6443 | kubectl via rewritten kubeconfig |
| Workers → control plane | TCP 6443 | k3s agent |
| k3s nodes → NFS VM | TCP/UDP 2049 (+ related NFS ports) | mounts / showmount |
| Your laptop → Proxmox | TCP 8006 | Terraform API |

Guests need outbound HTTPS to pull the k3s install script and (via the HelmChart controller) the provisioner chart.

## Standard day-2 commands

```bash
make plan       # preview VM / inventory diffs
make apply      # create/update VMs + regenerate inventory
make ansible    # full site.yml
make storage    # NFS StorageClass only
make verify     # nodes Ready + NFS export + StorageClass
make destroy    # typed confirmation; removes VMs + local kubeconfig/inventory
```

All of the above (except that `rebuild`/`destroy` are scripts) source `.env` via the Makefile.

## Scale the cluster

### Add a worker

1. Append an object to `workers` in `terraform/terraform.tfvars` (unique `name`, `vmid`, `ip`).
2. `make plan` → confirm one VM to add and inventory update.
3. `make apply`
4. `make ansible` (or, after a healthy CP exists: limit to the new host once token facts are available — simplest path is full `make ansible`).

### Remove a worker

1. Delete that entry from `workers`.
2. `make plan` → confirm **destroy** of that VM.
3. `make apply` — disk data on that VM is gone.
4. Optionally `kubectl delete node <name>` if the node object lingers; then `make verify`.

### Resize CPU / RAM / disk

Change the object in tfvars → `make plan` → `make apply`.

- CPU/RAM changes are usually in-place (guest reboot may be needed; Proxmox/provider behavior varies).
- **Disk growth** may force replacement depending on provider/disk config — read the plan carefully.
- Re-run `make ansible` only if you also changed network identity or need OS roles again.

### Change IP or hostname

1. Update tfvars.
2. `make apply` (regenerates inventory; may replace or reconfigure the VM).
3. `make ansible` so k3s URLs / NFS IP in the HelmChart stay correct.
4. Refresh local kubeconfig (re-run control-plane k3s role or full ansible) if the CP IP changed.

## Upgrade or reconfigure k3s

Install is **create-once** (skips if `/usr/local/bin/k3s` exists). Changing `k3s_version` or `k3s_server_args` in `roles/k3s/defaults/main.yml` does nothing until you reinstall:

**Option A — rebuild nodes (cleanest for a lab)**

```bash
make destroy    # type destroy
make rebuild
```

**Option B — in place**

```bash
# on each node (example)
sudo systemctl stop k3s k3s-agent || true
sudo /usr/local/bin/k3s-uninstall.sh   # server
# or: sudo /usr/local/bin/k3s-agent-uninstall.sh
make ansible
```

After any reinstall that rewrote kubeconfig, use the new repo-root `kubeconfig`.

## NFS and storage day-2

| Goal | Action |
|------|--------|
| Re-apply StorageClass / provisioner only | `make storage` |
| Change export path or client CIDR | Update tfvars → `make apply` → `make ansible` (nfs_server + provisioner) |
| Grow NFS disk | Increase `nfs_server.disk_gb` → plan/apply; then grow filesystem inside the guest if needed (not automated) |
| PVC smoke | See [nfs-storage.md](nfs-storage.md) / `manifests/storage/README.md` |

**Reclaim `Retain`:** deleting a PVC does **not** delete the subdirectory on the NFS server. Clean leftover dirs under the export path manually when you intend to reclaim space.

## Destroy and rebuild

### What `make destroy` does

1. Prompts you to type `destroy`
2. `terraform destroy` — all managed Proxmox VMs (k3s + NFS)
3. Deletes local `kubeconfig` and `ansible/inventory/hosts.proxmox.yml`

### What it does **not** do

- Remove Terraform state backups or `.terraform/`
- Uninstall anything from your laptop except those two files
- Wipe Proxmox templates or datastores beyond the VM disks destroyed with the VMs
- Clean Ansible Galaxy collections

### Full recreate

```bash
make rebuild
# terraform init/apply → wait for SSH on all inventory hosts → site.yml → verify.yml
```

Requires `terraform.tfvars` and a working `.env` token + SSH access to guests.

## Scripts map

| Script | Role |
|--------|------|
| `scripts/rebuild.sh` | End-to-end bring-up (auto-approve apply) |
| `scripts/destroy.sh` | Tear-down with confirmation |
| `scripts/create-ubuntu-template.sh` | Run **on the Proxmox host** once; see [proxmox-template.md](proxmox-template.md) |

## Verify coverage vs smoke test

| Check | `make verify` | Manual smoke |
|-------|---------------|--------------|
| All k3s nodes Ready | yes | — |
| NFS export visible (`showmount`) | yes | — |
| StorageClass `nfs` exists | yes | — |
| PVC binds / writes data | no | `kubectl apply -f manifests/storage/pvc-smoke.yaml` |

## Troubleshooting

| Symptom | Likely cause | What to try |
|---------|--------------|-------------|
| `PROXMOX_VE_API_TOKEN` / 401 from provider | Token missing or wrong | Confirm `.env` sourced; token format `user@realm!id=secret` |
| Cloud-init / disk datastore error on apply | `snippet_datastore` lacks **images** | Use `local-lvm` (or another images-capable store); see [proxmox-template.md](proxmox-template.md) |
| Plan wants to replace VMs unexpectedly | Clone drift / import | `lifecycle.ignore_changes = [clone]` should prevent clone-based replace; check other forced-new attrs |
| Rebuild stuck on SSH dots | cloud-init slow, wrong key, wrong IP | Console in Proxmox; `ssh -v` with the lab key; confirm IP in inventory |
| Ansible unreachable | Wrong `ANSIBLE_PRIVATE_KEY_FILE` / user | Match tfvars public key; test bare SSH |
| Traefik still installed | Old k3s install without `--disable traefik` | Reinstall k3s (create-once); confirm role defaults |
| Workers: missing `k3s_cluster_token` | CP play did not run first | Run full `site.yml`, not workers-only on a fresh cluster |
| `showmount` fails | NFS role/CIDR/firewall | `make ansible` with nfs in inventory; ensure `nfs_client_cidr` covers nodes |
| StorageClass never appears | HelmChart / wrong NFS IP | `kubectl -n kube-system get helmchart`; `make storage`; check inventory NFS IP |
| PVC Pending | Provisioner or mount | `kubectl -n nfs-provisioner get pods`; mount from a node; check Retain leftovers |
| kubectl connection refused / wrong host | Stale kubeconfig | Re-run ansible (fetch + rewrite) or fix server URL to CP `ansible_host:6443` |
| Inventory missing | Never applied / destroyed | `make apply` — do not hand-write `hosts.proxmox.yml` |

## Decision cheat sheet

| Change | First | Then |
|--------|-------|------|
| VM count / size / IP | `make apply` | `make ansible` if identity or new hosts |
| Packages, NFS export, k3s, StorageClass | — | `make ansible` or `make storage` |
| Only confirm health | — | `make verify` (+ optional PVC smoke) |
| Wipe lab | `make destroy` | `make rebuild` when ready |
