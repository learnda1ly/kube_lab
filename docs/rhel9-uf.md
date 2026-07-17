# RHEL 9 Splunk Universal Forwarder test lab

Three RHEL 9 VMs on Proxmox for Ansible-driven UF install/upgrade testing.
**Fully separate from the k3s cluster** — own Terraform root, state, inventory, and playbooks.

Related: [terraform.md](terraform.md) (k3s) · [ansible.md](ansible.md) (k3s) · [operations.md](operations.md)

## Why separate

| Path | Root | Inventory | Purpose |
|------|------|-----------|---------|
| k3s lab | `terraform/` | `hosts.proxmox.yml` | Cluster + NFS |
| RHEL 9 UF | `terraform/rhel9/` | `hosts.rhel9.yml` | UF install/upgrade only |

`make apply` / `make destroy` never touch the RHEL 9 VMs. `make rhel9-apply` / `make rhel9-destroy` never touch k3s.

## Default topology

| Host | VMID | IP | Role |
|------|------|-----|------|
| `rhel9-uf-01` | 240 | `192.168.1.40` | UF test |
| `rhel9-uf-02` | 241 | `192.168.1.41` | UF test |
| `rhel9-uf-03` | 242 | `192.168.1.42` | UF test |

LAN bridge `vmbr0` (same underlay as the laptop / k3s LAN so UF can reach lab Splunk `:9997` / `:8089` if desired). Not part of the k3s inventory.

## Prerequisites

1. **RHEL 9 cloud-init template** on Proxmox (separate from Ubuntu `template_id` 9000). Set its VMID in `terraform/rhel9/terraform.tfvars`.
2. Official RHEL cloud images typically use SSH user `cloud-user` (override `ssh_user` if your template differs).
3. Hosts need RHEL content (RHSM / Satellite / mirror) for OS packages. Splunk UF itself comes from a **custom dnf repo** or a local RPM (see below).
4. Copy `terraform/rhel9/terraform.tfvars.example` → `terraform/rhel9/terraform.tfvars` and fill endpoint, keys, `template_id`.

### One-time: create the RHEL 9 template

Official RHEL KVM/cloud qcow2 images are **not** publicly wget-able (unlike Ubuntu). Download once from [Red Hat](https://access.redhat.com) / Developer, then:

```bash
# On your laptop — path to the downloaded qcow2
scp /path/to/rhel-9.*-x86_64-kvm.qcow2 squinlan@192.168.1.228:/var/tmp/rhel-9-x86_64-kvm.qcow2
scp scripts/create-rhel9-template.sh squinlan@192.168.1.228:/tmp/
ssh -t squinlan@192.168.1.228 \
  'sudo IMAGE_PATH=/var/tmp/rhel-9-x86_64-kvm.qcow2 bash /tmp/create-rhel9-template.sh'
```

Defaults: VMID `9001`, name `rhel-9-cloud`, `ciuser=cloud-user`, serial console (same pattern as the Ubuntu template).

Do **not** convert an existing installed guest (e.g. VMID 103) into this template — Terraform expects a small cloud-init image like `9000`.

## Bring-up

```bash
cp terraform/rhel9/terraform.tfvars.example terraform/rhel9/terraform.tfvars
# edit tfvars — especially template_id and ssh_public_keys

make rhel9-init
make rhel9-plan
make rhel9-apply
make rhel9-ansible   # installs/upgrades Splunk UF
```

Equivalent without Make:

```bash
set -a && source .env && set +a
terraform -chdir=terraform/rhel9 init
terraform -chdir=terraform/rhel9 apply
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook -i ansible/inventory/hosts.rhel9.yml \
  ansible/playbooks/splunk_uf.yml
```

## Splunk UF package sources

### Custom dnf repo (Satellite-like)

Host N and N+1 UF RPMs behind HTTP, run `createrepo`, point hosts at it:

```ini
# written by the role when splunk_uf_package_source=repo
baseurl=http://<repo-host>/repos/splunk-uf/
```

Override in inventory/group vars or `-e`:

```bash
make rhel9-ansible EXTRA='-e splunk_uf_repo_baseurl=http://192.168.1.228/repos/splunk-uf/'
```

Pin a version for controlled upgrade tests:

```bash
make rhel9-ansible EXTRA='-e splunk_uf_version=9.3.2-d8bb32809498'
# later bump version / publish newer RPM to the repo, then:
make rhel9-ansible EXTRA='-e splunk_uf_version=9.4.0-....'
```

### Local RPM

```bash
cp /path/to/splunkforwarder-*.rpm ansible/roles/splunk_uf/files/
make rhel9-ansible EXTRA='-e splunk_uf_package_source=local -e splunk_uf_rpm_src=splunkforwarder-9.3.2-....x86_64.rpm'
```

## License acceptance

Not permanent across upgrades. The role always starts with:

`--accept-license --answer-yes --no-prompt`

after a package change.

## Config preservation

- RPM upgrade updates binaries; it does not wipe `$SPLUNK_HOME/etc/system/local/` or DS apps.
- Ansible deploys `outputs.conf` / `deploymentclient.conf` with **`force: false`** (create once, never overwrite).
- Deployment Server apps under `etc/apps/` are left alone.

## Destroy

```bash
make rhel9-destroy
```

Uses `terraform/rhel9` state only — k3s VMs are untouched.
