# Proxmox cloud-init template

Terraform clones an existing Proxmox template. Create one once on your node, then set `template_id` in `terraform.tfvars`.

## Ubuntu 24.04 example

```bash
# On the Proxmox node
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 9000 --name ubuntu-24.04-cloud --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
qm template 9000
```

## Datastore for snippets

The `bpg/proxmox` provider writes cloud-init snippets to `snippet_datastore` (default `local`). Ensure that datastore has the **Snippets** content type enabled in Datacenter → Storage.

## API token

Create a token with enough privileges to manage VMs (PVEVMAdmin on the pool/node is a common starting point). Export it as:

```bash
export PROXMOX_VE_API_TOKEN='user@pam!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```