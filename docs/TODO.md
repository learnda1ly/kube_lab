# TODO — simplify and tighten

Status after the cleanup pass. Items are checked when done; deferred items explain why.

## P1 — fix before they bite

- [x] **Collapse `group_vars` into one real path**  
  Vars live at `ansible/inventory/group_vars/all/main.yml`. Symlink and top-level `ansible/group_vars/` removed.

- [x] **Align k3s defaults with group_vars**  
  Canonical `k3s_server_args` (including `--disable traefik`) is in `roles/k3s/defaults/main.yml`. Inventory group_vars no longer duplicate conflicting args.

- [x] **Source `.env` from Makefile day-2 targets**  
  `plan` / `apply` / `ansible` / `storage` / `verify` / `init` use `with_env` (same idea as `scripts/rebuild.sh`).

- [x] **Clean up `.env.example` vs Terraform**  
  Dropped unused `PROXMOX_VE_ENDPOINT` / `PROXMOX_VE_INSECURE`. Kept `PROXMOX_VE_API_TOKEN` plus `ANSIBLE_USER` / `ANSIBLE_PRIVATE_KEY_FILE`.

## P2 — dual sources of truth

- [x] **Single NFS provisioner source**  
  Deleted `manifests/storage/nfs-provisioner.yaml`. Canonical path remains the Ansible role; `manifests/storage/README.md` points at PVC smoke only.

- [x] **Remove unused variables**  
  Removed `k3s_channel`. Stopped exporting `cluster_name` into Ansible inventory (still used for Proxmox VM tags).

- [x] **Deduplicate NFS path defaults**  
  `nfs_server` role asserts path/CIDR from inventory; role defaults keep only options/packages. Verify/provisioner no longer hardcode `/srv/nfs/k3s` fallbacks.

- [x] **Fix remaining doc / ignore drift**  
  - **Rejected “say Snippets” for `snippet_datastore`:** that datastore is the cloud-init **drive** and must support **images** (proved by the earlier apply failure on `local`). Docs updated to say images; variable name is historical.  
  - `.gitignore` no longer mentions `ansible/files/kubeconfig` (kubeconfig is repo-root).

## P3 — modest simplifications

- [x] **Don’t run full `common` on NFS hosts**  
  `common_prepare_kubernetes: false` on the NFS play skips br_netfilter / sysctl / swapoff.

- [x] **`storage.yml` vs last play of `site.yml`**  
  Shared `playbooks/nfs_provisioner.yml`; both `site.yml` and `storage.yml` `import_playbook` it.

- [x] **NFS `exportfs -ra` twice**  
  Handler-only on `/etc/exports` change (removed unconditional every-run `exportfs`).

- [x] **Empty role scaffold dirs**  
  Removed empty `files/` / `handlers/` / `templates/` under `common` and `k3s`.

- [x] **Template script vs proxmox doc**  
  `docs/proxmox-template.md` prefers `scripts/create-ubuntu-template.sh`; script comments are generic; README layout links the script.

- [ ] **DRY Terraform VM resources** — **deferred**  
  Optional module for shared clone/cloud-init blocks. Not urgent; skipping to avoid churn while the lab is live.

## P4 — behavior gaps (document or implement)

- [x] **k3s install is create-once** — **documented** in `docs/ansible.md` (upgrade = remove binary or rebuild VMs, then re-run). No auto-reinstall path added.

- [x] **`verify.yml` does not smoke-test a PVC** — **documented** (manual `kubectl apply -f manifests/storage/pvc-smoke.yaml` next to verify). Left out of verify to keep it non-mutating.

- [ ] **No playbook tags** — **deferred**  
  Separate playbooks + `--limit` are enough for this lab size.

- [x] **Makefile vs rebuild env parity**  
  Day-2 Make targets and `rebuild.sh` both source `.env` when present.

## Done when

Duplicate sources of truth, the group_vars symlink, and the worst doc drift are cleaned up. Remaining deferrals are optional TF DRY and playbook tags — not blocking the TF → inventory → site → verify path.
