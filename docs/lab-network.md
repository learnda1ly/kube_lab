# Lab network (vmbr1 NAT)

Separate Proxmox bridge for **non-k3s** VMs (today: `nfs-01`). Internet via Proxmox MASQUERADE; no router/switch changes required.

k3s stays on the LAN (`vmbr0` / `192.168.1.0/24`). Lab VMs live on `vmbr1` / `10.10.10.0/24`. Proxmox forwards so cluster nodes can still mount NFS.

```text
Internet → router 192.168.1.254 → vmbr0 (LAN)
                                    │
                    ┌───────────────┼────────────────┐
                    │               │                │
                 pve .228      k3s .20–.22      (operator)
                    │
                    │ NAT + forward
                    ▼
              vmbr1 10.10.10.0/24  GW 10.10.10.1
                    │
                 nfs-01 .30
```

Related: [operations.md](operations.md) · [terraform.md](terraform.md) · [nfs-storage.md](nfs-storage.md) · [zero-trust.md](zero-trust.md)

## One-time: create the bridge on Proxmox

Run **as root on the Proxmox host** (same pattern as the Ubuntu template script):

```bash
scp scripts/setup-lab-bridge.sh user@192.168.1.228:/tmp/
ssh -t user@192.168.1.228 'sudo bash /tmp/setup-lab-bridge.sh'
```

Defaults (override with env vars):

| Variable | Default | Meaning |
|----------|---------|---------|
| `BRIDGE` | `vmbr1` | Linux bridge name |
| `BRIDGE_CIDR` | `10.10.10.1/24` | Proxmox IP on the lab bridge (guest gateway) |
| `LAB_NET` | `10.10.10.0/24` | Lab CIDR for MASQUERADE / forward |
| `WAN_IFACE` | `vmbr0` | Uplink bridge toward the LAN / internet |

The script:

1. Writes `/etc/network/interfaces.d/vmbr1`
2. Enables `net.ipv4.ip_forward`
3. Installs `/usr/local/sbin/kube-lab-nat.sh` (iptables FORWARD + MASQUERADE)
4. Hooks `if-up.d` so rules return after reboot
5. Brings `vmbr1` up

Verify on the host:

```bash
ip addr show vmbr1
iptables -t nat -S | grep kube-lab
iptables -S FORWARD | grep kube-lab
```

## Operator laptop route

Your Mac/PC is on `192.168.1.0/24` and does not learn `10.10.10.0/24` from the home router. Add a static route via Proxmox:

```bash
# macOS
sudo route -n add -net 10.10.10.0/24 192.168.1.228

# Linux
sudo ip route add 10.10.10.0/24 via 192.168.1.228
```

Without this, SSH to `nfs-01` and Ansible against the lab net will time out even when the VM is healthy.

## Terraform / Ansible

| Knob | Where | Default |
|------|-------|---------|
| `lab_network` | tfvars | bridge `vmbr1`, gateway `10.10.10.1`, DNS |
| `nfs_server.ip` | tfvars | `10.10.10.30` |
| `lab_cidr` | tfvars → inventory | `10.10.10.0/24` |
| `proxmox_lan_ip` | tfvars → inventory | `192.168.1.228` |
| `nfs_client_cidr` | tfvars | **k3s** LAN `192.168.1.0/24` |

Ansible installs a persistent netplan route on **k3s nodes** so they reach `lab_cidr` via `proxmox_lan_ip` (required for NFS mounts).

After changing NFS network identity:

```bash
make apply
make ansible
make verify
```

## Ports across the boundary

| From → to | Service |
|-----------|---------|
| k3s nodes → nfs-01 | TCP/UDP 2049 (+ NFS helpers) |
| Operator (with route) → nfs-01 | TCP 22 |
| Lab VMs → internet | HTTPS via PVE MASQUERADE |

k3s ↔ k3s and operator → k3s stay on the LAN and are unchanged.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Cannot SSH to `10.10.10.30` from laptop | Missing laptop route | Add route via `.228` |
| k3s PVC mount hangs / NFS timeout | Missing guest route or PVE forward | `make ansible`; re-run host NAT script |
| Lab VM has no internet | MASQUERADE / ip_forward | `sysctl net.ipv4.ip_forward`; `kube-lab-nat.sh up` |
| `showmount` from CP fails | Route or export CIDR | Ping `10.10.10.30` from CP; confirm `nfs_client_cidr` is the k3s LAN |
