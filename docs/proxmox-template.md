# Proxmox cloud-init template

Terraform clones an existing Proxmox template. Create one once on your node, then set `template_id` in `terraform.tfvars`.

Related: [overview.md](overview.md) · [terraform.md](terraform.md) · [operations.md](operations.md)

## Preferred: use the helper script

[`scripts/create-ubuntu-template.sh`](../scripts/create-ubuntu-template.sh) downloads Ubuntu 24.04 cloudimg, creates VMID `9000` (override with `VMID=`), and converts it to a template.

```bash
scp scripts/create-ubuntu-template.sh user@proxmox:/tmp/
ssh -t user@proxmox 'sudo bash /tmp/create-ubuntu-template.sh'
```

Optional env overrides on the Proxmox host:

| Variable | Default | Meaning |
|----------|---------|---------|
| `VMID` | `9000` | Template VMID (`template_id` in tfvars) |
| `NAME` | `ubuntu-24.04-cloud` | Proxmox name |
| `STORAGE` | `local-lvm` | Disk + cloud-init drive datastore |
| `BRIDGE` | `vmbr0` | NIC bridge |
| `IMAGE_URL` | Ubuntu noble cloudimg | Source image |

The script aborts if the VMID already exists.

## Manual equivalent

```bash
# On the Proxmox node
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 9000 --name ubuntu-24.04-cloud --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot order=scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
qm template 9000
```

## Datastore for cloud-init

`initialization.datastore_id` (`snippet_datastore` in tfvars, default `local-lvm`) must support content-type **images** — that is where Proxmox stores the cloud-init CD-ROM. The Terraform variable name is historical; this is **not** the Proxmox “Snippets” content type.

Separately, enable **Snippets** on a directory datastore (often `local`) only if you use snippet-based cloud-init elsewhere. This lab’s provider path uses the cloud-init **drive** on an images-capable store.

## SSH keys on clones

Terraform injects `ssh_public_keys` from tfvars via cloud-init into each clone. Your laptop must have the matching private key:

- Put the public key in `terraform.tfvars` → `ssh_public_keys`
- Put the private key path in `.env` → `ANSIBLE_PRIVATE_KEY_FILE`
- Keep `ssh_user` / `ANSIBLE_USER` aligned (default `ubuntu`)

You do **not** need to bake your key into the template itself if cloud-init keys are set in Terraform (recommended).

## API token

1. In Proxmox UI: **Datacenter → Permissions → API Tokens** (or user → API Tokens).
2. Create a token for a user that can manage VMs on the target node (home lab: `PVEAdmin` on `/` is fine; tighten later if you want).
3. Copy the secret **once** (it is shown only at creation).
4. Put it in `.env` (not in git):

```bash
export PROXMOX_VE_API_TOKEN='user@pam!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

Format: `USERNAME@REALM!TOKENID=SECRET`.

Also set in tfvars: `proxmox_endpoint`, `proxmox_node`, `proxmox_insecure` (often `true` for lab certs). Leave `proxmox_api_token = null` so the env var is used.

The `bpg/proxmox` provider may also SSH to the Proxmox node as `proxmox_ssh_username` (default `root`) using your local SSH **agent**. Ensure agent auth to the hypervisor works before the first apply.

## After the template exists

```bash
# terraform.tfvars
template_id = 9000   # or whatever VMID you used
```

Then continue with [overview.md](overview.md) one-time setup (`make init`, `make rebuild`).
