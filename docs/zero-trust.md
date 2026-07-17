# Zero Trust recommendations for kube_lab

Recommendations to move this Proxmox + Terraform + Ansible + k3s + NFS lab toward a **Zero Trust** posture. Framed on the **DoD Zero Trust** model.

> **Note on “six pillars”:** The DoD Zero Trust Strategy / Reference Architecture defines **seven** pillars. People sometimes drop or fold **Automation & Orchestration**. This document covers all seven. Data sits at the center of the DoD model: every other pillar exists to protect data and missions that depend on it.

**References (external):** NIST SP 800-207; DoD Zero Trust Strategy; DoD Zero Trust Reference Architecture.

**Scope:** Anything in *this* environment — operator laptop, Proxmox host, API tokens, guest VMs, k3s control plane/workers, NFS, in-cluster workloads, and the rebuild pipeline.

**Lab reality check:** Full DoD Target-level ZT is not the goal of a home lab. Use these recommendations as a **maturity roadmap**: adopt High-value / High-feasibility items first; treat Target items as design goals when you add apps (e.g. Splunk) or expose services.

---

## Current posture (honest baseline)

| Area | Today (typical) | ZT tension |
|------|-----------------|------------|
| Network | Cluster LAN + lab NAT (`vmbr1`); trust by subnet within each | Implicit trust once on the wire; cross-segment via PVE forward |
| Identity | SSH keys + Proxmox API token; no MFA | Single-factor, long-lived secrets |
| Devices | Ubuntu cloud clones; guest agent optional | No continuous device health gate |
| Workloads | k3s; Traefik off; open to whatever you deploy | No default mTLS / policy engine |
| Data | NFS with `no_root_squash`, mode `0777`, reclaim Retain | Broad filesystem trust for provisioner convenience |
| Visibility | Ad hoc `kubectl` / Proxmox UI | No central telemetry or detection |
| Automation | Make / Ansible rebuild | Strong for *rebuild*, weak for *policy response* |

---

## Pillar 1 — User

**Intent:** Continuously authenticate and authorize people and non-person identities (NPE); least privilege; no standing broad access.

### Recommendations

| Priority | Action | Why / how it maps here |
|----------|--------|-------------------------|
| **P0** | Split identities: Proxmox admin ≠ Ansible deploy ≠ day-2 `kubectl` | Separate blast radius for hypervisor vs guests vs API |
| **P0** | MFA on Proxmox UI and any remote access to the hypervisor | User pillar starts at the control plane of the lab |
| **P0** | Replace shared/long-lived Proxmox API tokens with **short-lived** tokens or per-purpose tokens (plan-only vs apply) | Limits stolen `.env` impact |
| **P1** | Prefer SSH certificates (e.g. smallstep/Teleport) or short-lived keys over permanent `ssh_public_keys` in tfvars | Continuous auth for operators |
| **P1** | Introduce Kubernetes auth: OIDC (e.g. Dex + IdP) or short-lived kubeconfigs; stop relying on a standing `kubeconfig` with cluster-admin | NPE and human access to the API server |
| **P1** | Privileged Access Management pattern: break-glass admin account; daily work via limited roles (`view`, namespace admin) | PAM for k3s |
| **P2** | Just-in-time elevation (time-boxed `cluster-admin`) via OIDC groups or an approval bot | Removes standing God-mode |
| **P2** | Inventory all NPEs: Terraform token, Ansible, HelmChart controllers, provisioner SA — each with minimal RBAC | DoD treats non-person entities as first-class |

### Anti-patterns to retire

- One Proxmox token in `.env` used for everything forever  
- Cluster-admin kubeconfig on disk with mode that is broadly readable (`--write-kubeconfig-mode 644` is convenient, not ZT)  
- Same SSH user/key for NFS, workers, and control plane with no distinction  

---

## Pillar 2 — Device

**Intent:** Know every device; assess health/compliance continuously; deny or limit access from unknown or unhealthy endpoints.

### Recommendations

| Priority | Action | Why / how it maps here |
|----------|--------|-------------------------|
| **P0** | Asset inventory as code: Terraform state + Proxmox tags (`cluster_name`, role) as source of truth; alert on unknown VMs | Device inventory |
| **P0** | Harden the **operator laptop**: disk encryption, OS updates, SSH agent hygiene, no plaintext tokens in shell history | Your laptop is the highest-risk device |
| **P1** | Enforce guest baselines via Ansible: unattended-upgrades, fail2ban or equivalent, disable password SSH, auditd | Device configuration integrity |
| **P1** | Turn on and **monitor** qemu-guest-agent / virtio (TF currently disables waiting on agent — keep hang workaround, but still run agent for inventory signals) | Device posture signals to Proxmox |
| **P1** | Image integrity: pin template build; checksum cloud images; rebuild templates on a schedule; never mutate golden templates in place | Trusted device provenance |
| **P2** | Node attestation / measured boot where hardware allows; at minimum Secure Boot on Proxmox hosts | Device trust before join |
| **P2** | Admission: only nodes with expected labels/taints and recent patch level may schedule sensitive workloads | Comply-to-connect for k8s nodes |
| **P2** | Separate admin jump host (bastion) VM; operator never SSHes flat to every node from an unmanaged phone/laptop | Device trust boundary |

### Anti-patterns to retire

- Unknown VMs on the same bridge as k3s  
- Long-lived templates with unpatched kernels  
- Treating “it’s on my LAN” as device authorization  

---

## Pillar 3 — Network / Environment

**Intent:** No implicit trust by location; encrypt and segment; microsegmentation; software-defined perimeters where useful.

### Recommendations

| Priority | Action | Why / how it maps here |
|----------|--------|-------------------------|
| **P0** | Segment: management VLAN (Proxmox), cluster VLAN (k3s), storage VLAN (NFS), optional user/workload VLAN | Break the flat `192.168.1.0/24` trust |
| **P0** | Firewall default-deny between segments; allow only documented flows (see [operations.md](operations.md) port table, then shrink it) | Explicit paths only |
| **P0** | TLS everywhere north-south: terminate ingress with cert-manager + private CA or ACME; no plain HTTP to apps | Encrypted access paths |
| **P1** | k3s network policies (or Cilium/Calico policies) default-deny in sensitive namespaces | East-west microsegmentation |
| **P1** | Isolate NFS: export only to k3s node CIDR (already started with `nfs_client_cidr`); prefer dedicated storage VLAN + NFSv4 + Kerberos later | Storage is not “just another host” |
| **P1** | Control-plane protection: API server not exposed beyond management/operator segment; optional WireGuard/Tailscale overlay for remote admin (identity-aware) | Environment-specific access |
| **P2** | Service mesh (Cilium mTLS or Linkerd/Istio) for workload-to-workload authn/z | Microseg at L7 |
| **P2** | Proxmox firewall + guest firewall (ufw/nftables) as defense in depth; SDN/VXLAN if you grow multi-node Proxmox | Environment hardening |
| **P2** | DNS privately controlled; no reliance on public DNS for internal service discovery without validation | Environment integrity |

### Target allow-list mindset (examples)

| Source | Destination | Service |
|--------|-------------|---------|
| Operator overlay | Proxmox | 8006/tcp |
| Operator overlay | CP | 6443/tcp, 22/tcp (bastion preferred) |
| Workers | CP | 6443/tcp (+ k3s required ports only) |
| k3s nodes | NFS | 2049 (+ required NFS helpers) on storage VLAN |
| Ingress | Apps | 443/tcp only |

Deny everything else by default.

---

## Pillar 4 — Application & Workload

**Intent:** Secure software from build through runtime; isolate workloads; authenticate APIs; least privilege for services.

### Recommendations

| Priority | Action | Why / how it maps here |
|----------|--------|-------------------------|
| **P0** | Kubernetes RBAC least privilege; ban anonymous access; review default SAs | Workload identity at API |
| **P0** | Pod Security: enforce PSS `restricted` (or equivalent Kyverno/OPA policies) on app namespaces | Workload isolation |
| **P0** | Image hygiene: pull only from known registries; pin digests; optional Trivy/Grype in CI before deploy | Secure SDLC for what you run |
| **P1** | NetworkPolicy + deny egress by default for apps that do not need the internet | Limit C2 and exfil paths |
| **P1** | Separate system vs app namespaces; taints/tolerations so user workloads cannot land on CP | Trust zones inside the cluster |
| **P1** | Replace convenience NFS provisioner posture over time: avoid `no_root_squash` where possible; use CSI with stronger auth when ready | Workload access to storage |
| **P1** | Secrets: External Secrets / Sealed Secrets / SOPS — never bake secrets into git or cloud-init userdata beyond bootstrap | App secret handling |
| **P2** | Admission controllers: Kyverno/OPA Gatekeeper (require labels, deny `:latest`, require non-root) | Policy as gate |
| **P2** | Runtime security: Falco or Tetragon for syscall anomaly detection | Workload runtime assurance |
| **P2** | Sign & verify images (cosign) and optionally Kubernetes manifests | Supply chain |

### Anti-patterns to retire

- cluster-admin kubeconfig for app deploys  
- Privileged pods / hostNetwork “just to make it work”  
- NFS export world-writable mindset for production-like apps  

---

## Pillar 5 — Data

**Intent:** Identify, classify, encrypt, and control data access; monitor use; minimize sprawl.

### Recommendations

| Priority | Action | Why / how it maps here |
|----------|--------|-------------------------|
| **P0** | Classify lab data: **secrets** (tokens, kubeconfig), **infra state** (tfstate), **workload PV data**, **logs** | You cannot protect what you have not labeled |
| **P0** | Encrypt secrets at rest on the operator machine; restrict `.env` / `tfstate` / `kubeconfig` permissions (`0600`); prefer SOPS-encrypted tfvars secrets | Data at rest (operator) |
| **P0** | Enable Proxmox storage encryption or LUKS on guest disks for sensitive VMs where CPU allows | Data at rest (infrastructure) |
| **P1** | Encrypt NFS in transit (stunnel, WireGuard between nodes and NFS, or NFSv4 + kerberos) — plain NFS on a flat LAN is cleartext | Data in transit |
| **P1** | Tighten export: drop `0777` where feasible; per-PVC ownership; consider `root_squash` + provisioner redesign | Data access control |
| **P1** | Backup with encryption and tested restore (Proxmox backup, k3s etcd, NFS datasets) — availability is part of data assurance | Data resilience |
| **P2** | Label PVCs/namespaces by sensitivity; policy that high-sensitivity data only schedules on hardened nodes | Data-centric zoning |
| **P2** | DLP-lite: block unexpected egress of large volumes from namespaces holding sensitive PVCs | Data exfil detection |
| **P2** | etcd encryption at rest for k3s secrets | Kubernetes secret confidentiality |

### High-value data stores in this repo’s design

1. Proxmox API token / SSH keys  
2. Terraform state (can contain sensitive values)  
3. k3s etcd / secrets  
4. NFS export contents (future Splunk indexes, app data)  
5. Fetched kubeconfig on the laptop  

---

## Pillar 6 — Visibility & Analytics

**Intent:** Continuous monitoring, correlation, and detection so access decisions and response are informed by reality—not assumptions.

### Recommendations

| Priority | Action | Why / how it maps here |
|----------|--------|-------------------------|
| **P0** | Centralize logs: Proxmox syslog, guest auth logs, k3s audit log, ingress access logs → one store (even a small Loki/ELK/Splunk on NFS) | Without visibility, ZT is theater |
| **P0** | Enable Kubernetes **audit logging** on the control plane | Who did what to the API |
| **P1** | Metrics + alerts: node ready, unexpected nodes, API server auth failures, NFS mount failures, privileged pod creates | Analytics on critical events |
| **P1** | Inventory drift detection: compare Proxmox VM list vs Terraform state on a schedule | Unauthorized devices/workloads |
| **P1** | Capture flow metadata (Cilium Hubble, or firewall logs) between segments | Network visibility |
| **P2** | UEBA-lite: alert on new SSH key use, API token use from new source IP, kubectl from unexpected CIDR | User/device analytics |
| **P2** | Retain logs with integrity controls (WORM or append-only bucket) for forensics | Trusted telemetry |
| **P2** | Map detections to each pillar (failed MFA, unhealthy node join, policy deny, sensitive PVC egress) | Pillar-aligned SOC view |

### Minimum signal set for this lab

- SSH accept/reject on all VMs  
- Proxmox auth + VM create/destroy  
- k3s audit: secrets, RBAC bindings, exec/attach  
- NFS: mount/export changes  
- Terraform apply identity (who ran apply, from where)  

---

## Pillar 7 — Automation & Orchestration

**Intent:** Policy decision and enforcement automated, consistent, and reversible; human speed is too slow for ZT.

### Recommendations

| Priority | Action | Why / how it maps here |
|----------|--------|-------------------------|
| **P0** | Keep **rebuildability** (already a strength): IaC + Ansible as the only supported config path; ban snowflake UI changes | Orchestrated desired state |
| **P0** | Policy-as-code in CI: `terraform validate`/`tflint`, `ansible-lint`, manifest checks before merge | Automated gate before change |
| **P1** | GitOps (Flux/Argo CD) for cluster workloads — drift detection + auto-reconcile | Continuous enforcement |
| **P1** | Automated response playbooks: revoke API token, cordon node, apply deny-all NetworkPolicy, snapshot VM on alert | Orchestrated containment |
| **P1** | Certificate automation (cert-manager) with short TTLs | Removes manual trust paper cuts |
| **P2** | Admission + SOAR: webhook denies + ticket/alert; optional auto-rollback of bad HelmChart | Closed-loop control |
| **P2** | Dynamic authorization hooks (e.g. OPA with external data: device inventory, time of day) | Continuous decisioning |

Your Make/`rebuild.sh` pipeline is a head start on Automation—extend it from “build the lab” to “enforce and respond.”

---

## Suggested adoption roadmap

### Phase A — Foundations (weeks)

1. Segment networks (mgmt / cluster / storage) — **started**: k3s on LAN `vmbr0`, NFS/non-k3s on Proxmox NAT `vmbr1` ([lab-network.md](lab-network.md)); tighten firewall allow-list next  
2. MFA on Proxmox; split API tokens; lock down kubeconfig permissions  
3. Enable k3s audit logs + ship auth logs to a single place  
4. PSS baseline + basic NetworkPolicies on default/app namespaces  

### Phase B — Enforce (1–2 months)

5. OIDC for Kubernetes; short-lived credentials  
6. GitOps for apps; Kyverno/OPA policies  
7. Encrypt NFS path or move sensitive data off cleartext NFS  
8. Image scanning + pinned digests  

### Phase C — Target-style (ongoing)

9. Service mesh mTLS  
10. Runtime detection (Falco/Tetragon) + automated containment  
11. Device compliance gates for operator access (Teleport/device posture)  
12. Full secret/etcd encryption and classified-style data labels if the lab hosts sensitive datasets  

---

## Mapping: DoD pillars → kube_lab components

```text
                    ┌──────────── Visibility & Analytics ────────────┐
                    │  logs, audit, flows, drift, alerts             │
                    └──────────────────────┬─────────────────────────┘
                                           │
   User ──► IdP/MFA/SSH certs/OIDC ──► decisions ──► Automation
   Device ─► inventory/posture/patch ─┘                │
                                                       ▼
              Network segments + firewall + NetworkPolicy + mesh
                                                       │
              Application/Workload: PSS, RBAC, admission, images
                                                       │
                                           ┌───────────▼───────────┐
                                           │         DATA          │
                                           │ secrets, etcd, NFS,   │
                                           │ backups, tfstate      │
                                           └───────────────────────┘
```

| Component | Primary pillars |
|-----------|-----------------|
| Operator laptop + `.env` | User, Device, Data |
| Proxmox host / API | User, Device, Network, Visibility |
| Terraform / Ansible | Automation, User (NPE), Data (state) |
| k3s CP / workers | Device, Network, Application, Visibility |
| NFS VM + StorageClass | Data, Network, Application |
| Ingress / future apps | User, Application, Data, Network |

---

## What not to do

- Declare “Zero Trust” because you installed a mesh while leaving flat NFS, cluster-admin kubeconfigs, and a single forever API token  
- Buy a product per pillar without **segmentation + identity + logging** first  
- Copy DoD Target controls onto a three-node lab overnight—prefer measurable Phase A outcomes  

---

## Related lab docs

- [overview.md](overview.md) — architecture and ownership  
- [operations.md](operations.md) — ports, day-2, troubleshooting  
- [ansible.md](ansible.md) — NFS posture (`no_root_squash`, export CIDR)  
- [nfs-storage.md](nfs-storage.md) — data path for PVs  
- [TODO.md](TODO.md) — engineering cleanups (orthogonal but complementary)
