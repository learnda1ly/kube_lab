# OpenShift on this Proxmox stack

Investigation of how to deploy **OpenShift / OKD** on the existing `kube_lab` Proxmox + Terraform + Ansible pattern, with a path that can later run **air-gapped**.

This is a design note, not an implementation. Today the lab installs **k3s** on Ubuntu cloud-init clones; OpenShift needs a different bootstrap model.

---

## What you have today

| Layer | Current behavior | OpenShift impact |
|-------|------------------|------------------|
| Terraform (`bpg/proxmox`) | Clone Ubuntu template, static IP via cloud-init | Cluster nodes should **not** be Ubuntu clones; they boot an **agent ISO** onto empty disks and install RHCOS/FCOS |
| Ansible | `common` + `k3s` (curl `get.k3s.io`) | Install path moves to agent ISO + (optional) mirror registry; Ansible becomes infra/bootstrap, not kubelet install |
| Sizing defaults | 2 vCPU / 4 GiB / 40 GiB per node | Far below OpenShift minima (see below) |
| Network | Flat `vmbr0`, optional VLAN, public DNS defaults | Need local DNS (+ VIP/LB for multi-node) before install |
| Rebuild script | apply → SSH wait → site.yml → verify | Same outer shape, but middle steps become ISO generate → attach/boot → wait for `openshift-install agent wait-for` |

Reusable pieces: Proxmox API token flow, `.env` / tfvars pattern, inventory generation, `make rebuild` orchestration, common OS prep for **helper VMs** (bastion, DNS, registry).

---

## Product choice: OKD vs OpenShift

| | **OKD** | **OpenShift Container Platform (OCP)** |
|--|---------|----------------------------------------|
| Cost | Free / community | Subscription + pull secret |
| OS on nodes | FCOS (Fedora CoreOS) | RHCOS |
| Installer | `openshift-install` (OKD builds) | `openshift-install` (Red Hat builds) |
| Air-gap | Mirror from OKD/quay release streams | Mirror via `oc-mirror` / Mirror Registry for OpenShift |
| Best when | Homelab, learning, no Red Hat entitlement | Production-like, Operators from RH catalogs, support |

**Recommendation for this repo:** start with **OKD** (or OCP if you already have a pull secret), using the **Agent-based Installer (ABI)**. ABI is the method designed for on-prem + disconnected; Proxmox is treated as generic bare-metal/KVM VMs (`platform: baremetal` or `none`).

---

## Recommended install method: Agent-based Installer

Do **not** try to Ansible-install packages onto Ubuntu the way k3s is done. OpenShift expects an immutable CoreOS install driven by the installer.

### Why ABI fits Proxmox + air-gap

1. You generate a single **agent ISO** locally (`openshift-install agent create image`).
2. The ISO embeds Assisted Service — no dependency on Red Hat’s hosted Assisted Installer SaaS.
3. Proxmox VMs boot that ISO; discovery, validation, and install orchestration stay on-LAN.
4. For disconnected installs, point `install-config.yaml` at a **local mirror registry** (`imageContentSources` / ImageDigestMirrorSet) and ship the mirrored content with the ISO build host.

Official overview: [OKD installation methods](https://docs.okd.io/latest/installing/overview/index.html) · [OCP agent-based installer](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html).

### Topology options (pick one to start)

| Topology | Nodes | Per-node floor | When to use |
|----------|-------|----------------|-------------|
| **SNO** (single-node) | 1 control plane (schedulable) | 8 vCPU / 16 GiB / 120 GiB | Prove the pattern; smallest air-gap pilot |
| **Compact** | 3 masters (also workers) | 8 / 16 / 120 each | Small HA without dedicated workers |
| **HA** | 3 masters + 2+ workers | 8 / 16 / 120 each | Closer to production shape |

Your current tfvars (2/4/40 × 3) cannot host OpenShift. Plan host capacity first; SNO alone wants roughly **8 cores + 16+ GiB RAM + 120+ GiB disk** on one VM, plus helper VMs.

---

## Target architecture on this stack

```text
Connected staging          oc-mirror / oc adm release mirror
(or one-time laptop)  -->  tarball / USB  -->  air-gapped LAN
                                                    |
                                                    v
+------------------------------------------------------------------+
| Proxmox                                                          |
|                                                                  |
|  +--------------+   DNS A/PTR + (multi-node) HAProxy/VIP         |
|  | bastion      |<---------------------------------------------+ |
|  | Ubuntu       |  openshift-install, oc, mirror tooling       | |
|  | (cloud-init) |                                              | |
|  +------+-------+                                              | |
|         | builds agent.iso, uploads to Proxmox storage         | |
|         v                                                      | |
|  +--------------+  +--------------+  +--------------+          | |
|  | ocp-m1       |  | ocp-m2       |  | ocp-w1       |  ...     | |
|  | empty disk   |  | (compact/HA) |  | (HA only)    |          | |
|  | boot agent   |  |              |  |              |          | |
|  | ISO -> CoreOS|  |              |  |              |          | |
|  +--------------+  +--------------+  +--------------+          | |
|         ^ pull release images from local registry -------------+ |
|  +--------------+                                                |
|  | registry     |  Mirror Registry / Quay / Harbor (Ubuntu VM)   |
|  +--------------+                                                |
+------------------------------------------------------------------+
```

For a **connected** first pass, omit the registry VM and let nodes pull from quay/registry.redhat.io. Keep the same Terraform/Ansible shapes so disconnecting later is a config flip, not a redesign.

---

## How Terraform should change

Keep the provider/auth/`make apply` flow. Split VM classes:

### 1. Helper VMs (still Ubuntu cloud-init clones)

Reuse the existing clone pattern in `terraform/main.tf` for:

- **bastion** — runs `openshift-install`, `oc`, builds the agent ISO, holds kubeconfig
- **registry** (air-gap) — Mirror Registry for OpenShift, or Harbor/Quay
- optional **dns-lb** — dnsmasq/CoreDNS + HAProxy if you do not already have LAN DNS/LB

These VMs keep `common` Ansible role patterns (packages, qemu-guest-agent, etc.).

### 2. Cluster nodes (empty VMs + fixed MAC + ISO boot)

New resources (conceptually):

- Create VMs **without** cloning the Ubuntu template (or clone then wipe / use blank disk).
- Pin **stable MAC addresses** (Terraform → `agent-config.yaml` must match).
- Attach blank disk ≥ 120 GiB; boot order: CD-ROM (agent ISO) then disk.
- Upload `agent.iso` to a Proxmox datastore (`local` ISO storage), attach as IDE/SATA CD-ROM.
- After install completes, detach ISO / set boot to disk (day-2 automation).

Inventory groups should become something like:

```yaml
all:
  children:
    helpers:
      children:
        bastion: ...
        registry: ...
    openshift_cluster:
      children:
        masters: ...
        workers: ...
```

Do not put OpenShift nodes in a “SSH then apt install k3s” playbook path; after CoreOS is up you manage them with `oc` / MachineConfig, not classic Ansible package installs.

### Example sizing sketch (replace k3s defaults)

```hcl
# Connected SNO pilot — adjust IPs to your LAN
bastion = { name = "ocp-bastion", cores = 2, memory = 4096, disk_gb = 80, ip = "192.168.1.30" }

# Air-gap add-on
# registry = { name = "ocp-registry", cores = 4, memory = 8192, disk_gb = 500, ip = "192.168.1.31" }

control_plane = {
  name    = "ocp-m1"
  vmid    = 210
  cores   = 8
  memory  = 20480   # 20 GiB preferred over bare 16
  disk_gb = 120
  ip      = "192.168.1.40"
  mac     = "BC:24:11:00:00:40"  # fixed; used in agent-config.yaml
  cidr    = 24
}
workers = []  # SNO: empty; compact/HA: add masters/workers similarly
```

---

## Networking, DNS, and VIPs

OpenShift is stricter than k3s here. Before generating the ISO:

### DNS (required)

For cluster `homelab` and base domain `example.local`:

| Record | Points to |
|--------|-----------|
| `api.homelab.example.local` | API VIP (or SNO node IP) |
| `api-int.homelab.example.local` | same (internal API) |
| `*.apps.homelab.example.local` | Ingress VIP (or SNO node IP) |
| Per-node A + **PTR** | each master/worker IP |

PTR records matter: CoreOS uses reverse DNS for hostnames/CSRs when DHCP does not supply names. Missing PTRs are a common install failure.

Your current `dns_servers = ["1.1.1.1", "8.8.8.8"]` is fine for Ubuntu helpers on a connected LAN, but cluster nodes (and clients using the API/apps URLs) need a resolver that serves the records above — typically dnsmasq on the bastion, Pi-hole, or router local zones.

### Platform choice on Proxmox

| `platform` | VIPs | Notes |
|------------|------|-------|
| `none` | You provide external LB/DNS; often used for **SNO** | Supported for SNO with `OVNKubernetes` |
| `baremetal` | Set `apiVIPs` / `ingressVIPs`; keepalived-style VIP managed by platform | Good for compact/HA on Proxmox VMs on the same L2 |

For multi-node on a home flat network, **`baremetal` + API/Ingress VIPs on the same bridge** is usually simpler than standing up HAProxy yourself. For SNO, **`none`** with DNS A records straight to the node IP is enough.

### Machine network

Keep cluster nodes on the existing `bridge` / optional `vlan_id`. Ensure the bastion can reach node IPs and that nodes can reach the registry (air-gap) and VIPs.

---

## Ansible’s new job

Replace (or parallelize beside) the k3s role with plays roughly like:

1. **helpers/common** — packages, timezone, guest agent (existing role, mostly reusable).
2. **dns_lb** — zone files / dnsmasq + optional HAProxy; verify dig/PTR.
3. **registry** (air-gap) — install Mirror Registry or Quay; load mirrored content; publish CA.
4. **agent_config** — render `install-config.yaml` + `agent-config.yaml` from Terraform outputs (IPs, MACs, pull secret, mirror CA, SSH key).
5. **agent_iso** — on bastion: `openshift-install agent create image`; fetch ISO; upload to Proxmox (API or `scp` + `pvesm`).
6. **boot** — ensure VMs boot ISO (Terraform or `qm set`); start VMs.
7. **wait** — `openshift-install agent wait-for bootstrap-complete` / `wait-for install-complete`; fetch kubeconfig.
8. **verify** — `oc get nodes`, clusteroperators — analogous to today’s `verify.yml`.

Keep `scripts/rebuild.sh` as the conductor; swap the Ansible entry playbook (`site-openshift.yml`) rather than overloading k3s `site.yml` until you decide on a multi-distro lab.

---

## Install config sketch (SNO, platform none)

Rendered on the bastion (secrets via Ansible vault / `.env`, not git):

```yaml
# install-config.yaml (illustrative)
apiVersion: v1
metadata:
  name: homelab
baseDomain: example.local
compute:
  - name: worker
    replicas: 0
controlPlane:
  name: master
  replicas: 1
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: 192.168.1.0/24
platform:
  none: {}
pullSecret: '{"auths":{...}}'
sshKey: 'ssh-ed25519 AAAA...'
# Air-gap only:
# additionalTrustBundle: |
#   -----BEGIN CERTIFICATE-----
#   ...
# imageContentSources:
#   - mirrors:
#       - registry.homelab.example.local:8443/openshift/release
#     source: quay.io/openshift-release-dev/ocp-release
#   - mirrors:
#       - registry.homelab.example.local:8443/openshift/release
#     source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
```

```yaml
# agent-config.yaml (illustrative)
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: homelab
rendezvousIP: 192.168.1.40   # first master; runs Assisted Service
hosts:
  - hostname: ocp-m1
    role: master
    rootDeviceHints:
      deviceName: /dev/sda    # confirm virtio/scsi device name in the guest
    interfaces:
      - name: enp6s18         # confirm Proxmox virtio NIC name
        macAddress: BC:24:11:00:00:40
    networkConfig:
      interfaces:
        - name: enp6s18
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.1.40
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.1.30    # bastion/dnsmasq
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.1.1
            next-hop-interface: enp6s18
            table-id: 254
```

Then:

```bash
openshift-install agent create image --dir=./ocp-install
# upload agent.iso to Proxmox, attach, start VM
openshift-install agent wait-for install-complete --dir=./ocp-install
```

---

## Air-gapped adaptation (design so connected work is not throwaway)

Treat “connected” and “disconnected” as two values of the same pipeline.

### Content you must stage

On a machine that *can* reach the internet (laptop or temporary bastion):

1. Download `openshift-install` + `oc` matching the release.
2. Mirror release images (and later operator catalogs you care about):
   - OCP: [Mirror Registry for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/installing-mirroring-creating-registry) + `oc-mirror` / `oc adm release mirror`
   - OKD: mirror the OKD release stream into the same style of local registry
3. Export mirror artifacts (registry disk tarball, `ImageContentSourcePolicy` / IDMS fragments, installer binary).
4. Transfer via USB/sneakernet into the air-gapped LAN.
5. Load into the **registry** VM; put CA into `additionalTrustBundle`; rebuild agent ISO; boot nodes.

### What stays identical offline

- Terraform VM shapes, MACs, IPs, bridges
- DNS/VIP hostnames
- `agent-config.yaml` host networking
- Rebuild orchestration

### What changes offline

- Bastion has **no** default route to the internet (or a deny-all egress)
- `install-config` mirror blocks + trust bundle populated
- Registry VM sized for the mirror (hundreds of GiB for a full release + operators)
- NTP: local chrony/NTP source (CoreOS/OpenShift are time-sensitive)
- No `curl | sh` patterns (unlike current k3s role) — everything is pre-staged binaries/images

### Practical tip

Implement **registry + imageContentSources wiring first**, even while the registry still proxies/pulls online. Then cut egress and confirm install still works from the mirror only. That is the cheapest way to validate air-gap readiness.

---

## Gap analysis vs current repo

| Area | Gap | Suggested direction |
|------|-----|---------------------|
| Node OS bootstrap | Ubuntu template + cloud-init | Blank disk + agent ISO for cluster nodes |
| CPU/RAM/disk defaults | 2/4/40 | ≥ 8/16/120 (SNO); more for compact/HA |
| DNS | Public resolvers only | Local authoritative zone for `api` / `*.apps` + PTR |
| LB/VIP | None (k3s single API on node) | SNO: DNS→node; multi-node: `baremetal` VIPs or HAProxy |
| Install automation | Ansible installs k3s | Ansible/bastion runs ABI; `oc` for verify |
| Secrets | Proxmox token + SSH | Add pull secret (OCP), registry creds, mirror CA |
| Storage for apps | open-iscsi/nfs-common preinstalled | Day-2: LVMS / NFS / Rook — out of install scope |
| Ingress | Traefik disabled on k3s | OpenShift ships router; DNS `*.apps` required |
| Air-gap | Entirely online (`get.k3s.io`) | Mirror registry VM + staged installer |

---

## Suggested implementation phases

### Phase 0 — Capacity and DNS

- Confirm Proxmox node has RAM/CPU/disk for SNO + bastion.
- Stand up local DNS (even manually) for `api` / `*.apps` / PTR.
- Decide OKD vs OCP and obtain pull secret if OCP.

### Phase 1 — Connected SNO on Proxmox (prove ABI)

- Terraform: bastion + one empty VM with fixed MAC.
- Manual or scripted: generate agent ISO, attach, install.
- Document NIC name (`enp*`) and root disk (`/dev/sda` vs `vda`) for your template of VM hardware.
- Do **not** delete the k3s path yet; add `docs` + optional `terraform/openshift/` or feature flag.

### Phase 2 — Automate in-repo

- Terraform modules/vars for helpers vs cluster nodes.
- Ansible roles: `dns`, `agent_iso`, `wait_install`.
- `make rebuild-openshift` alongside existing k3s rebuild.

### Phase 3 — Disconnected path

- Registry VM + mirror load playbooks.
- `install-config` mirror fragments from oc-mirror output.
- Offline rebuild test (bastion without internet).

### Phase 4 — Compact/HA (optional)

- Three masters, VIPs, extra workers.
- Stronger backup for etcd / registry volume.

---

## Risks and footguns specific to this lab

1. **Undersizing** — install will hang or OOM if you keep 4 GiB nodes.
2. **MAC / NIC / disk name mismatch** — `agent-config.yaml` must match Proxmox virtio device names; validate once interactively.
3. **DNS/PTR** — hardest “invisible” failure mode; test with `dig`/`getent` before `create image`.
4. **ISO datastore** — Proxmox storage must allow ISO upload; separate from `snippet_datastore` if needed.
5. **qemu-guest-agent** — useful on helpers; on CoreOS it arrives via OpenShift MachineConfig, not your Ubuntu `common` role.
6. **Subscription drift** — OCP mirroring requires valid entitlements; OKD avoids that but has different operator catalogs.
7. **Nested virt / CPU type** — you already use `cpu.type = "host"`; keep that for CoreOS performance and pass-through features.

---

## What not to do

- Do not install kubelet/CRI-O onto the existing Ubuntu VMs and expect a supported OpenShift cluster.
- Do not assume the Assisted Installer web UI (SaaS) will work air-gapped — use **agent-based** local ISO.
- Do not start with full HA + full operator mirror on day one; SNO connected → SNO mirrored → expand.

---

## References

- Current lab flow: [README.md](../README.md), [docs/proxmox-template.md](proxmox-template.md)
- OCP Agent-based Installer: https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html
- OCP disconnected / mirror registry: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/installing-mirroring-creating-registry
- OKD install overview: https://docs.okd.io/latest/installing/overview/index.html
- Community ABI helpers / sizing: https://red-hat-se-rto.github.io/openshift-agent-install/platform-guides.html
- Example air-gapped ABI notes: https://github.com/rguske/openshift-agent-based-installer-airgapped
