# instructions.md — Agent brief for kube_lab

**Audience:** The next agent (or human) improving this repository.  
**Purpose:** Capture every requirement already addressed so you can build a *better* version without rediscovering design, regressions, or tribal knowledge.  
**Style:** Treat this as a contract. Prefer improving the implementation *while preserving* the hard requirements unless the human explicitly changes them.

Read this file first, then deepen via the linked docs. Do **not** invent a parallel architecture that bypasses Terraform → inventory → Ansible.

---

## 0. How to use this document

1. Skim **§1 Mission** and **§2 Hard requirements** — these are non-negotiable unless the user says otherwise.
2. Before changing behavior, check **§10 Pitfalls** and **§12 Do not regress**.
3. When adding features, update the **layer doc of truth** (§11) and this file’s checklist if a new requirement is established.
4. Prefer small, coherent PRs: infra vs config vs docs when splitting helps review.
5. Secrets stay out of git. Never commit `.env`, `terraform.tfvars`, `kubeconfig`, or state.

---

## 1. Mission

Build and operate a **rebuildable Kubernetes home lab** on **Proxmox**:

- **Terraform** creates VMs (k3s control plane, workers, dedicated NFS) and writes Ansible inventory.
- **Ansible** configures OS, NFS export, k3s, and StorageClass `nfs`.
- **Make/scripts** orchestrate init → apply → configure → verify → destroy.

Success looks like: `make destroy` then `make rebuild` yields a working cluster with Ready nodes, a visible NFS export, and StorageClass `nfs`, without hand-editing inventory or clicking Proxmox into a snowflake state.

This is a **lab**, not a multi-tenant production platform. Convenience choices are documented; Zero Trust is a **roadmap** (`docs/zero-trust.md`), not the current baseline.

---

## 2. Hard requirements (must remain true)

| ID | Requirement |
|----|-------------|
| H1 | **Rebuildable** — wipe VMs, re-apply TF + Ansible, get the same shape |
| H2 | **Pipeline** — `terraform apply` → `ansible/inventory/hosts.proxmox.yml` → `site.yml` → `verify.yml` |
| H3 | **Inventory is generated** — never hand-edit `hosts.proxmox.yml`; change topology in `terraform.tfvars` then apply |
| H4 | **Terraform does not install** k3s, NFS server packages, or Kubernetes objects |
| H5 | **Ansible does not create** VMs or assign IPs (reads inventory only; not TF state) |
| H6 | **NFS is a dedicated VM**, not Proxmox shared storage — same rebuild path as compute |
| H7 | **NFS hosts are not k3s nodes** — separate TF resource; inventory `nfs` group is a **sibling** of `k3s_cluster` |
| H8 | **Single control plane** — join token / `K3S_URL` from `groups['control_plane'][0]`; CP play before workers |
| H9 | **NFS provisioner is Ansible-owned** — no duplicate static HelmChart under `manifests/`; app manifests (e.g. Splunk) are fine under `manifests/<app>/` |
| H10 | **Secrets not committed** — only `*.example` files for local secrets; see `.gitignore` |
| H11 | **IaC is the only supported config path** — no “fix it in the Proxmox UI” as the documented workflow |
| H12 | **Prereqs stay documented** — Terraform `>= 1.5`, Ansible `>= 2.15`, Galaxy collections, Ubuntu cloud-init template, SSH keys, `PROXMOX_VE_API_TOKEN` |

**Decision rule when changing something:**

1. VMs / hardware / network identity → Terraform first  
2. Packages / exports / k3s / StorageClass → Ansible  
3. IP or hostname change → `make apply` (inventory) then `make ansible`

---

## 3. Architecture ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `terraform/` | Proxmox VMs, static IPs, cloud-init user/keys, sizes, tags, generated inventory (+ `nfs_export_path` / `nfs_client_cidr`) | OS packages, k3s, NFS daemon, HelmChart, kubeconfig semantics |
| `ansible/` | OS prep, NFS export, k3s install/join, provisioner HelmChart, fetch/rewrite kubeconfig | Creating VMs or choosing IPs |
| `manifests/storage/` | PVC smoke test only | Provisioner install |
| `manifests/splunk/` | Standalone Splunk + NFS PVCs | Provisioner install / VM sizing |
| `Makefile` + `scripts/` | Orchestration | Cluster semantics |
| `.env` | `PROXMOX_VE_API_TOKEN`, `ANSIBLE_USER`, `ANSIBLE_PRIVATE_KEY_FILE` | `proxmox_endpoint` / `proxmox_insecure` (tfvars) |
| `terraform.tfvars` | Endpoint, node, template, datastores, cluster bridge/VLAN, lab_network, gateway/DNS, topology, NFS object, public keys | Prefer `proxmox_api_token = null` so token stays in env |

Providers: `bpg/proxmox` `~> 0.70`, `hashicorp/local` `~> 2.5`. Local Terraform state only (no remote backend configured).

---

## 4. Default topology (addressed)

Change via tfvars; defaults live in `terraform/variables.tf` / `terraform.tfvars.example`.

| Role | Name | VMID | IP | Network | vCPU | RAM MiB | Disk GiB |
|------|------|------|-----|---------|------|---------|----------|
| Control plane | `k3s-cp-01` | 200 | `192.168.1.20` | LAN `vmbr0` | 2 | 4096 | 40 |
| Worker | `k3s-wk-01` | 201 | `192.168.1.21` | LAN `vmbr0` | 2 | 4096 | 40 |
| Worker | `k3s-wk-02` | 202 | `192.168.1.22` | LAN `vmbr0` | 2 | 4096 | 40 |
| NFS | `nfs-01` | 210 | `10.10.10.30` | lab `vmbr1` | 2 | 2048 | 200 |

Also addressed:

- Cluster: `gateway` / `cidr` / `dns_servers` / `bridge` / optional `vlan_id`
- Lab: `lab_network` / `lab_cidr` / `proxmox_lan_ip` (underlay via `scripts/setup-lab-bridge.sh`)
- `vm_datastore` + `snippet_datastore` default `local-lvm`
- `template_id` default `9000` (Ubuntu 24.04 cloud-init)
- `cluster_name` default `homelab` — **Proxmox tags only**; not exported to Ansible inventory
- `ssh_user` default `ubuntu`
- Full clone, CPU `host`, disk `raw` + `discard`, `stop_on_destroy`, OS `l26`
- Tags: k3s → `[cluster_name, "k3s", role]`; NFS → `[cluster_name, "nfs"]`

### StorageClass `nfs` (addressed)

| Knob | Value |
|------|-------|
| Default class | **false** (`local-path` remains default) |
| Reclaim | `Retain` |
| Access | RWX via chart |
| Mechanism | k3s `HelmChart` → nfs-subdir-external-provisioner |
| Export | `/srv/nfs/k3s` to `nfs_client_cidr` (default k3s LAN `192.168.1.0/24`) |
| Options | `rw,sync,no_subtree_check,no_root_squash` |
| Dir mode | `0777` (lab convenience) |

### k3s (addressed)

- Version pin: `v1.31.4+k3s1` in `ansible/roles/k3s/defaults/main.yml`
- Server args: `--disable traefik` + `--write-kubeconfig-mode 644` (**canonical in role defaults**)
- Install create-once (skip if `/usr/local/bin/k3s` exists)
- Kubeconfig fetched to repo-root `kubeconfig`; rewrite `127.0.0.1:6443` → CP `ansible_host:6443`

### Inventory shape (addressed)

```text
all
├── k3s_cluster
│   ├── control_plane
│   ├── workers
│   └── vars: lab_cidr, proxmox_lan_ip
└── nfs                    # sibling, not under k3s_cluster
    └── vars: nfs_export_path, nfs_client_cidr
```

Per host: `ansible_host`, `ansible_user`.

---

## 5. Implemented feature checklist

Use this as a regression checklist when refactoring.

### Terraform

- [x] `for_each` k3s nodes from `local.nodes` (CP + workers)
- [x] Separate `proxmox_virtual_environment_vm.nfs`
- [x] `local_file` Ansible inventory generator
- [x] Outputs: `control_plane_ips`, `worker_ips`, `nfs_server_ip`, `lab_cidr`, `lab_bridge`, `nfs_export_path`, `ansible_inventory_path`, `vm_ids`
- [x] `agent { enabled = false }` on k3s **and** NFS (PVE 9 hang workaround)
- [x] `lifecycle.ignore_changes = [clone]` on k3s nodes
- [x] `serial_device` + `vga { type = serial0 }` on k3s nodes (template parity)
- [x] API token from `PROXMOX_VE_API_TOKEN` when tfvars token is null
- [x] Provider SSH to Proxmox node via agent (`proxmox_ssh_username`, default `root`)
- [x] NFS on `lab_network` (`vmbr1`); inventory exports `lab_cidr` + `proxmox_lan_ip`

### Ansible

- [x] `common` role: timezone, apt, packages, qemu-guest-agent; k8s sysctl/swap gated by `common_prepare_kubernetes`
- [x] `lab_routes` on `k3s_cluster`: netplan route to lab CIDR via Proxmox LAN IP
- [x] NFS play: `common_prepare_kubernetes: false`
- [x] `nfs_server`: **assert** path/CIDR from inventory; handler-only `exportfs -ra`
- [x] `k3s` server then agents; token `delegate_facts` across `k3s_cluster`
- [x] Traefik disabled in role defaults (not a conflicting group_vars copy)
- [x] `nfs_provisioner` HelmChart template + wait for StorageClass
- [x] Shared `playbooks/nfs_provisioner.yml` imported by `site.yml` and `storage.yml`
- [x] Skip provisioner if `groups['nfs']` empty
- [x] `verify.yml`: nodes Ready == `|k3s_cluster|`; showmount export path; SC `nfs` exists; **non-mutating** (no PVC)
- [x] Galaxy: `community.general >= 8.0.0`, `ansible.posix >= 1.5.0`
- [x] Inventory-adjacent group_vars only: `ansible/inventory/group_vars/all/main.yml`
- [x] Packages: curl, ca-certificates, open-iscsi, nfs-common, jq, qemu-guest-agent
- [x] Timezone default: `America/Chicago`

### Orchestration

- [x] `make init|plan|apply|ansible|storage|verify|rebuild|destroy`
- [x] Makefile `with_env` sources `.env` for day-2 targets (parity with rebuild/destroy scripts)
- [x] `rebuild.sh`: init → apply `-auto-approve` → SSH wait → galaxy → site → verify
- [x] `destroy.sh`: typed `destroy` → TF destroy → delete local kubeconfig + inventory
- [x] `create-ubuntu-template.sh` for one-time Proxmox template (VMID 9000 defaults)
- [x] `setup-lab-bridge.sh` for one-time Proxmox `vmbr1` NAT lab network

### Manifests / docs

- [x] `manifests/storage/pvc-smoke.yaml` + README pointing at Ansible provisioner
- [x] Docs: overview, terraform, ansible, operations, proxmox-template, nfs-storage, lab-network, zero-trust, TODO
- [x] Cleanup pass recorded in `docs/TODO.md` (dual sources removed; deferrals called out)

### Explicitly cleaned / rejected (do not reintroduce)

- [x] No top-level `ansible/group_vars` + symlink hack
- [x] No unused `k3s_channel`
- [x] No `cluster_name` in Ansible inventory
- [x] No duplicate `manifests/storage/nfs-provisioner.yaml`
- [x] No unused `PROXMOX_VE_ENDPOINT` / `PROXMOX_VE_INSECURE` in `.env.example`
- [x] Do not “fix” `snippet_datastore` docs to say Proxmox **Snippets** — cloud-init **drive** needs **images** (variable name is historical)

---

## 6. Operational contract

### `.env` (gitignored)

```bash
PROXMOX_VE_API_TOKEN="user@pam!token=..."
ANSIBLE_USER="ubuntu"
ANSIBLE_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519"
```

Must match tfvars `ssh_user` / `ssh_public_keys`.

### Make targets

| Target | Meaning |
|--------|---------|
| `make init` | TF init + Galaxy |
| `make plan` / `apply` | Infra + regenerate inventory |
| `make ansible` | Full `site.yml` |
| `make storage` | Provisioner / StorageClass only |
| `make verify` | Readiness (nodes + NFS + SC) |
| `make rebuild` | End-to-end recreate |
| `make destroy` | Tear down VMs + local kubeconfig/inventory |

### site.yml order (canonical)

1. `common` + `lab_routes` → `k3s_cluster`  
2. `common` (k8s prep off) + `nfs_server` → `nfs`  
3. `k3s` → `control_plane` (`serial: 1`)  
4. `k3s` → `workers`  
5. `import_playbook: nfs_provisioner.yml` (if nfs group present)

### Verify vs smoke

| Check | `make verify` | Manual |
|-------|---------------|--------|
| Nodes Ready | yes | — |
| NFS export via showmount | yes | — |
| StorageClass `nfs` | yes | — |
| PVC binds | **no** | `kubectl apply -f manifests/storage/pvc-smoke.yaml` |

### Two SSH consumers (easy to break)

| Consumer | Auth |
|----------|------|
| Terraform → Proxmox **hypervisor** | SSH agent as `proxmox_ssh_username` |
| Ansible → **guest** VMs | `ANSIBLE_USER` + `ANSIBLE_PRIVATE_KEY_FILE` |
| `rebuild.sh` SSH wait | Bare `ssh user@host` — **does not** pass `ANSIBLE_PRIVATE_KEY_FILE` |

---

## 7. Security posture (as implemented)

**Intentional lab convenience (document if you change):**

- Flat LAN; long-lived API token; no MFA
- NFS `0777` + `no_root_squash`
- `host_key_checking = False` in `ansible.cfg`
- kubeconfig mode `644`
- Same SSH identity pattern across roles
- Local TF state; `proxmox_insecure` often true

**Roadmap (not implemented):** `docs/zero-trust.md` — DoD **seven** pillars (User, Device, Network/Environment, Application & Workload, Data, Visibility & Analytics, Automation & Orchestration). Phase A priority if hardening: segment networks → MFA/short-lived tokens → audit/logs → PSS/NetworkPolicy.

---

## 8. Non-goals and deferred work

Do not treat these as missing bugs unless the user asks for them:

| Item | Status |
|------|--------|
| DRY Terraform module for shared VM blocks | Deferred (`docs/TODO.md`) |
| Ansible playbook tags | Deferred — use `--limit` / `storage.yml` |
| Auto-upgrade k3s on re-run | Documented create-once; upgrade = uninstall or rebuild |
| PVC smoke inside `verify.yml` | Kept non-mutating on purpose |
| Splunk / app charts | Standalone manifests in `manifests/splunk/` (not Helm) |
| Ingress controller | Traefik deliberately disabled; none shipped |
| Remote Terraform backend | Not configured |
| HA / multi-control-plane k3s | Out of scope for current playbooks |
| Proxmox-as-NFS | Rejected |
| Full Zero Trust controls | Roadmap only |
| Auto-grow NFS filesystem after disk resize | Manual in guest |
| Ansible uninstall on destroy | Destroy removes VMs + local files only |

---

## 9. File ownership map (edit the right file)

| Concern | Edit here |
|---------|-----------|
| Mission / quickstart | `README.md`, `docs/overview.md` |
| TF providers / versions | `terraform/versions.tf`, `providers.tf` |
| Topology schema | `terraform/variables.tf` |
| Operator overrides | `terraform/terraform.tfvars` (from example) |
| VM + inventory resources | `terraform/main.tf` |
| TF outputs | `terraform/outputs.tf` |
| Timezone / packages | `ansible/inventory/group_vars/all/main.yml` |
| k3s version / Traefik-off | `ansible/roles/k3s/defaults/main.yml` |
| NFS path/CIDR | tfvars → generated inventory (role asserts) |
| NFS options/packages | `ansible/roles/nfs_server/defaults/main.yml` |
| StorageClass knobs | `ansible/roles/nfs_provisioner/` |
| Bring-up order | `ansible/playbooks/site.yml` |
| Day-2 SC | `storage.yml` → `nfs_provisioner.yml` |
| Readiness | `ansible/playbooks/verify.yml` |
| PVC smoke | `manifests/storage/pvc-smoke.yaml` |
| Splunk app | `manifests/splunk/` |
| Orchestration | `Makefile`, `scripts/*.sh` |
| Template one-time | `scripts/create-ubuntu-template.sh`, `docs/proxmox-template.md` |
| Day-2 runbook | `docs/operations.md` |
| ZT roadmap | `docs/zero-trust.md` |
| Engineering backlog | `docs/TODO.md` |
| **This contract** | `instructions.md` |

---

## 10. Pitfalls and lessons learned (encoded in code/docs)

| Pitfall | Rule |
|---------|------|
| PVE 9 + provider hangs on guest agent IP wait | Keep TF `agent.enabled = false`; still install qemu-guest-agent via Ansible |
| `snippet_datastore` confused with Snippets content type | Must support **images** (cloud-init drive); default `local-lvm`; name is historical |
| group_vars not loading | Keep vars under `ansible/inventory/group_vars/` next to the inventory **file** |
| Conflicting Traefik args | Single source: `roles/k3s/defaults` — do not re-duplicate conflicting group_vars |
| k3s create-once | Changing version/args requires binary removal / uninstall / VM rebuild |
| Import force-replace | `ignore_changes = [clone]` on k3s nodes |
| NFS in node pool | Never fold NFS into `local.nodes` |
| Silent NFS path defaults | Role **asserts** inventory vars — no fallback path |
| Double exportfs | Handler-only on `/etc/exports` change |
| rebuild SSH hang | `rebuild.sh` ignores `ANSIBLE_PRIVATE_KEY_FILE` — fix agent/`~/.ssh/config` or improve script |
| Workers before CP | Token fact missing — always run CP play first |
| Retain reclaim | PVC delete leaves NFS dirs — document cleanup |
| Dual provisioner YAML | Do not re-add static HelmChart twin under manifests |
| Apply from two laptops | Local state will diverge — remote backend or single operator |

---

## 11. Documentation sync rules

When behavior changes, update:

1. The **layer doc** (terraform / ansible / nfs / proxmox-template)  
2. `docs/operations.md` if day-2 steps or troubleshooting change  
3. `README.md` / `docs/overview.md` if the map, Make targets, or defaults change  
4. `docs/TODO.md` if debt is added/resolved  
5. `docs/zero-trust.md` baseline table if posture actually improves  
6. **This `instructions.md`** if a hard requirement or checklist item changes  

Prefer one source of truth for defaults (code + one doc), not three conflicting copies.

Deep dives:

- `docs/overview.md` — map  
- `docs/terraform.md` — infra  
- `docs/ansible.md` — config  
- `docs/operations.md` — day-2  
- `docs/nfs-storage.md` — storage  
- `docs/proxmox-template.md` — template  
- `docs/zero-trust.md` — hardening roadmap  
- `docs/TODO.md` — deferred cleanups  

---

## 12. Do not regress

A “better” version still fails if it:

1. Breaks TF → generated inventory → site → verify  
2. Makes Ansible invent host IPs or Terraform install k3s  
3. Puts NFS under `k3s_cluster` or installs k3s on NFS  
4. Reintroduces dual provisioner manifests or group_vars symlink indirection  
5. Re-enables TF guest-agent wait without proving the PVE hang is fixed  
6. “Fixes” snippet datastore docs to require Snippets instead of images  
7. Commits secrets, state, kubeconfig, or generated inventory  
8. Silently changes Traefik-on, default StorageClass to `nfs`, or multi-CP assumptions without updating all docs and playbooks  
9. Makes `verify.yml` mutate the cluster without an explicit separate smoke target  
10. Leaves day-2 Make targets unable to source `.env` while rebuild can  

---

## 13. Quality bar — make the next version better

Improve **without** violating §2 / §12. Highest-value directions:

### A. Engineering polish

1. DRY Terraform VM resources (shared module) **and** decide NFS parity for `serial`/`vga`/`ignore_changes`  
2. Make `rebuild.sh` SSH wait honor `ANSIBLE_PRIVATE_KEY_FILE`  
3. Optional `make smoke` that applies/deletes `pvc-smoke.yaml` (keep `verify` non-mutating)  
4. CI: `terraform validate` / `tflint`, `ansible-lint`, doc link check  
5. Remote state backend option for multi-machine operators  
6. Clearer k3s upgrade path (documented runbook or idempotent version gate)  

### B. Product / workloads

7. Expand app manifests (Splunk is the first consumer on `storageClassName: nfs`); size workers/NFS as needed  
8. Choose and document an ingress (Traefik stays off until replaced deliberately)  
9. Example app NetworkPolicies / PSS baseline as optional Ansible role or GitOps repo  

### C. Security maturity (from `docs/zero-trust.md` Phase A)

10. Network segments: mgmt / cluster / storage + default-deny  
11. MFA on Proxmox; short-lived / split API tokens; kubeconfig `0600`  
12. k3s audit logging + central log sink  
13. PSS + default-deny NetworkPolicies for app namespaces  
14. Tighten NFS (`0777` / `no_root_squash` / cleartext) as provisioner design allows  

### D. Docs / agent UX

15. Keep `instructions.md` updated when requirements change  
16. Prefer executable examples over prose duplication  
17. When closing a TODO, check the box and note the commit/PR  

---

## 14. Suggested workflow for the next agent

```text
1. Read instructions.md (§2, §10, §12)
2. Reproduce current happy path mentally: make rebuild → verify → pvc-smoke
3. Pick ONE improvement theme (A/B/C above) — don’t boil the ocean
4. Implement with tests/commands the human can run
5. Update layer docs + this file’s checklist
6. Call out any intentional requirement change for human approval
```

### Acceptance questions before you claim “done”

- [ ] Does `make plan` still make sense after my change?  
- [ ] Does inventory still regenerate from Terraform only?  
- [ ] Does `site.yml` order still bootstrap CP before workers and NFS before provisioner?  
- [ ] Did I avoid a second source of truth for provisioner / Traefik args / NFS path?  
- [ ] Did I update the right docs and avoid committing secrets?  
- [ ] Is the lab still rebuildable from empty VMs?  

---

## 15. Quick reference — important paths

```text
.env.example
Makefile
README.md
instructions.md                 ← you are here
docs/{overview,terraform,ansible,operations,nfs-storage,proxmox-template,zero-trust,TODO}.md
terraform/{main,variables,outputs,providers,versions}.tf
terraform/terraform.tfvars.example
ansible/ansible.cfg
ansible/requirements.yml
ansible/inventory/group_vars/all/main.yml
ansible/playbooks/{site,storage,verify,nfs_provisioner}.yml
ansible/roles/{common,lab_routes,k3s,nfs_server,nfs_provisioner}/
manifests/storage/{README.md,pvc-smoke.yaml}
manifests/splunk/
scripts/{rebuild,destroy,create-ubuntu-template}.sh
```

---

*Last inventory aligned with the post-NFS, post-docs-cleanup tree. If code and this file disagree, fix the disagreement — do not paper over it.*
