# NFS storage for the k3s lab

Dedicated Ubuntu VM (`nfs-01`) exports a share used by k3s for dynamic
PersistentVolumes. Proxmox itself is **not** the NFS server; the VM keeps
storage rebuildable through the same Terraform → Ansible path as the cluster.

See also [ansible.md](ansible.md) (`nfs_server` / `nfs_provisioner`) · [operations.md](operations.md) · [overview.md](overview.md).

## Architecture

```text
terraform apply
  → Proxmox VMs: k3s-cp / k3s-wk* / nfs-01
  → ansible/inventory/hosts.proxmox.yml (nfs group + export vars)

ansible site.yml
  → common (packages only on NFS; no k8s sysctls)
  → nfs_server: nfs-kernel-server + /etc/exports
  → k3s install
  → nfs_provisioner: HelmChart → StorageClass "nfs"
```

```text
Pod (e.g. Splunk)
  → PVC (storageClassName: nfs)
    → nfs-subdir-external-provisioner
      → mkdir on nfs-01:/srv/nfs/k3s/<ns>-<pvc>-...
        → NFS mount into the pod
```

Canonical provisioner install is **Ansible only** (`make ansible` / `make storage`). There is no duplicate static HelmChart under `manifests/` — only a PVC smoke test ([manifests/storage/README.md](../manifests/storage/README.md)).

## Defaults

| Setting | Value |
|---------|-------|
| VM | `nfs-01` (VMID `210`) |
| Network | lab `vmbr1` ([lab-network.md](lab-network.md)) |
| IP | `10.10.10.30/24` (gateway `10.10.10.1` on Proxmox) |
| Size | 2 vCPU, 2 GiB RAM, 200 GiB disk |
| Export | `/srv/nfs/k3s` → k3s LAN `192.168.1.0/24` (`nfs_client_cidr`) |
| Options | `rw,sync,no_subtree_check,no_root_squash` |
| StorageClass | `nfs` (not cluster default; `local-path` remains) |
| Reclaim | `Retain` |

`no_root_squash` lets the provisioner (root in-cluster) create PVC subdirectories.
The export is limited to the **k3s LAN** CIDR (`nfs_client_cidr` must include every k3s node). k3s nodes reach NFS via a static route through Proxmox (`lab_routes` role).

## Configure tfvars

```hcl
lab_network = {
  bridge      = "vmbr1"
  gateway     = "10.10.10.1"
  dns_servers = ["10.10.10.1", "1.1.1.1"]
}
lab_cidr       = "10.10.10.0/24"
proxmox_lan_ip = "192.168.1.228"

nfs_server = {
  name    = "nfs-01"
  vmid    = 210
  cores   = 2
  memory  = 2048
  disk_gb = 200
  ip      = "10.10.10.30"
  cidr    = 24
}

nfs_export_path = "/srv/nfs/k3s"
nfs_client_cidr = "192.168.1.0/24"
```

Terraform writes path/CIDR into inventory `nfs` group vars. The `nfs_server` role **requires** those inventory values (no silent role-default path).

## Bring-up

```bash
make apply      # creates nfs-01 + regenerates inventory
make ansible    # NFS export + k3s + StorageClass
make verify     # nodes Ready + showmount + StorageClass nfs
```

Day-2 StorageClass only (cluster + NFS already up):

```bash
make storage
```

NFS host OS only (after inventory exists):

```bash
make ansible
# or: ansible-playbook ... site.yml --limit nfs
```

### Guest agent note

Terraform keeps `agent { enabled = false }` on the NFS (and k3s) VM resources so PVE 9 + the provider do not hang waiting for guest IPs. Ansible’s `common` role still installs/enables `qemu-guest-agent` inside the guest for Proxmox UI niceties — that is independent of the Terraform agent flag.

## Smoke-test a PVC

`make verify` does **not** create a PVC. After StorageClass `nfs` exists:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl apply -f manifests/storage/pvc-smoke.yaml
kubectl get pvc nfs-smoke
# expect Bound; then:
kubectl delete -f manifests/storage/pvc-smoke.yaml
```

Because reclaim policy is `Retain`, delete the leftover directory under the export on `nfs-01` if you want the space back.

## Using the StorageClass in apps

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs
  resources:
    requests:
      storage: 20Gi
```

Mount that PVC from your Deployment/StatefulSet as usual. Prefer RWX only when you need shared writers; many apps are fine with a single writer on RWX.

## Day-2 NFS ops

| Goal | Steps |
|------|--------|
| Refresh provisioner | `make storage` |
| Change path/CIDR | tfvars → `make apply` → `make ansible` |
| Grow capacity | Increase `disk_gb` → apply → grow partition/FS inside guest (manual) |
| Inspect export | `showmount -e <nfs_ip>` from a node with `nfs-common` |

More detail: [operations.md](operations.md).

## Splunk (example consumer)

Standalone Splunk manifests live under [`manifests/splunk/`](../manifests/splunk/):

- PVCs `splunk-etc` / `splunk-var` use `storageClassName: nfs` for `/opt/splunk/etc` and `/opt/splunk/var`
- Deploy: copy `secret.yaml.example` → `secret.yaml`, set password, then `kubectl apply` per that README
- Size the NFS disk and worker RAM for the workload (Deployment requests 2 GiB RAM)
- Remember `Retain`: deleting Splunk PVCs leaves data on `nfs-01` until you remove those directories
