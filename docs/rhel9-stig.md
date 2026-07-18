# RHEL 9 STIG + IdM IaC proof of concept

Proof-of-concept path for a **fully IaC-managed, STIG-aligned RHEL 9** lab on Proxmox: Terraform provisions VMs, Ansible hardens to DISA STIG, OpenSCAP **maintains** compliance, and **Red Hat Identity Management (IdM)** owns users/groups/access.

Related: [rhel9-uf.md](rhel9-uf.md) (existing UF VMs) · [zero-trust.md](zero-trust.md) · [ansible.md](ansible.md)

---

## 1. Applicable STIGs (research summary)

### Primary (in scope for this PoC)

| STIG | Version (as of research) | Findings | How we automate |
|------|--------------------------|----------|-----------------|
| **Red Hat Enterprise Linux 9 STIG** | **V2R8** (2026-02-05); Red Hat content baselines often lag at **V2R7** per minor release | **446** total — CAT I **28** / CAT II **403** / CAT III **15** | SCAP Security Guide profile `xccdf_org.ssgproject.content_profile_stig` via OpenSCAP + Ansible |

**SCAP profile IDs (RHEL 9):**

- Headless / server: `xccdf_org.ssgproject.content_profile_stig`
- Server with GUI: `xccdf_org.ssgproject.content_profile_stig_gui`

**Important Red Hat constraint:** use the SSG profile shipped with the **same RHEL minor** you run. FIPS mode is expected for full STIG alignment (`fips-mode-setup`).

Sources: [DISA / Red Hat DISA STIG portal](https://access.redhat.com/compliance/disa-stig), [STIG Viewer RHEL 9](https://www.stigviewer.com/stigs/red_hat_enterprise_linux_9), ComplianceAsCode / `scap-security-guide`, [RedHatOfficial.rhel9_stig](https://github.com/RedHatOfficial/ansible-role-rhel9-stig) (generated from ComplianceAsCode, aligned to V2R8).

### Control domains covered by the RHEL 9 OS STIG (representative)

These are the categories remediation and audit playbooks target; CAT I items fail closed and must be reviewed with an ISSO before waivers:

| Domain | Examples |
|--------|----------|
| Patch / vendor support | Supported release; security updates current; GPG verification |
| Boot / integrity | GRUB password; AIDE; SELinux enforcing; secure boot where applicable |
| Identity / auth | SSSD/PAM; multifactor / PKI mapping; password quality; account lockout |
| Session / access | DoD banner; idle timeouts; Ctrl-Alt-Del disabled; sudoers |
| Cryptography | System-wide crypto policy; FIPS; SSH ciphers/MACs/KEX |
| Network | firewalld active; deny-all allow-by-exception; unused services removed |
| Audit / logging | `auditd` rules; journald; remote log shipping hooks |
| Filesystem | Partitioning / mount options; sticky bit; world-writable cleanup |

### Related STIGs (out of band unless you deploy those products)

| Product / layer | STIG / content | Notes for this architecture |
|-----------------|----------------|------------------------------|
| **Red Hat IdM / FreeIPA** | **No dedicated DISA STIG / SCAP content** | Harden the **RHEL 9 host** with the OS STIG; manage users/HBAC in IdM via Ansible (`ansible-freeipa`) |
| OpenShift / RHCOS | OpenShift STIG + Compliance Operator | Only if you later put workloads on OCP |
| Ansible Automation Controller | AAC STIG | If AAP becomes the runner |
| Application stacks | Apache, PostgreSQL, Tomcat, etc. | Apply when those services are installed |
| Network appliances / browsers | Separate DISA STIGs | Outside guest OS IaC |

### IdM + STIG interaction (design rules)

1. **Users are not local.** Local interactive accounts are minimized; day-to-day humans live in IdM (SSSD).
2. **HBAC / sudo / groups in IdM** replace ad-hoc `/etc/passwd` and scattered `sudoers` fragments.
3. **STIG SSSD/PKI findings** (e.g. certificate→account mapping) are satisfied by IdM-issued certs + SSSD certmap, not by inventing local users.
4. **Order of operations:** enroll IdM client **before** aggressive SSH/PAM STIG remediation when possible, or ensure a break-glass local admin + console access during first harden.
5. **FIPS / crypto policy** on IdM servers and clients must be consistent or enrollment and Kerberos will break.

---

## 2. Target architecture (PoC)

```text
Terraform (terraform/rhel9)
        │  clones RHEL 9 cloud-init VMs
        ▼
ansible/inventory/hosts.rhel9.yml
        │  groups: rhel9_uf, rhel9_stig, idm_clients
        ▼
┌───────────────────────────────────────────────────────────┐
│ Ansible                                                     │
│  1. idm_client     → ipa-client-install / freeipa.ipaclient │
│  2. rhel9_stig     → packages + OpenSCAP remediate (STIG) │
│  3. rhel9_stig_audit → oscap eval + report + optional fix │
│  4. (controller→IdM) idm_manage → users/groups/HBAC       │
└───────────────────────────────────────────────────────────┘
        │
        ▼
   Red Hat IdM (external or future TF VM)
        │  users, groups, HBAC, sudo rules, HBAC services
        ▼
   RHEL 9 members (SSSD) — STIG-hardened, periodically re-scanned
```

**Ownership split (same contract as the rest of kube_lab):**

| Layer | Owns |
|-------|------|
| Terraform | VMs, IPs, cloud-init user/keys, inventory groups |
| Ansible | Packages, IdM enrollment, STIG remediate, compliance timers/reports |
| IdM | Users, groups, HBAC, host groups, sudo rules (via Ansible against IdM API) |

k3s / NFS playbooks are **not** in this path. Reuse the existing RHEL 9 UF VMs as STIG targets for the PoC.

---

## 3. Ansible entry points

| Make target | Playbook | Purpose |
|-------------|----------|---------|
| `make rhel9-stig` | `playbooks/rhel9_stig_site.yml` | IdM client (if enabled) → STIG harden → audit scan |
| `make rhel9-stig-harden` | `playbooks/rhel9_stig_harden.yml` | Remediation only |
| `make rhel9-stig-audit` | `playbooks/rhel9_stig_audit.yml` | Scan / report; optional re-remediate drift |
| `make rhel9-idm-client` | `playbooks/idm_client.yml` | Enroll hosts into IdM |
| `make rhel9-idm-manage` | `playbooks/idm_manage.yml` | Ensure users/groups/HBAC on IdM server |

Defaults and toggles: `ansible/inventory/group_vars/rhel9_stig/main.yml` and `idm_clients/main.yml`.

Secrets (IdM admin password, OTP, etc.) stay in Ansible Vault or `.env` — never committed.

---

## 4. Compliance maintenance model

Hardening once is not enough. This PoC treats compliance as **continuous configuration**:

1. **Remediate** with OpenSCAP (`--remediate`) or the generated ComplianceAsCode Ansible content.
2. **Audit** on a schedule (systemd timer installed by `rhel9_stig_audit`) writing XML/HTML under `/var/log/compliance/`.
3. **Drift repair** by re-running `make rhel9-stig-audit EXTRA='-e rhel9_stig_remediate_on_audit=true'` (or a CI/AWX job).
4. **Evidence** — fetch reports to the controller (`rhel9_stig_fetch_reports`).
5. **Exceptions** — document waivers in inventory vars (`rhel9_stig_oscap_skip_rules`); do not silently disable CAT I without ISSO approval.

Lab note: full 100% STIG score often needs FIPS-at-install, specific partitioning, and hardware features. The PoC aims for **repeatable, auditable alignment**, not a claimed ATO.

---

## 5. Bring-up (lab)

Prerequisites: RHEL 9 template + content (RHSM/Satellite), existing `make rhel9-apply`, and (for IdM) a reachable IdM server + admin credentials.

```bash
# 1) VMs + inventory (unchanged UF lab root)
make rhel9-apply

# 2) Collections (includes freeipa.ansible_freeipa)
make init

# 3) Configure IdM + STIG vars (vault recommended)
#    ansible/inventory/group_vars/idm_clients/main.yml
#    ansible/inventory/group_vars/rhel9_stig/main.yml

# 4) Full STIG + IdM client path
make rhel9-stig

# 5) Day-2: re-scan / remediate drift
make rhel9-stig-audit
```

If IdM is not ready yet, set `idm_client_enabled: false` and run harden/audit alone.

---

## 6. Next increments (not in this PoC PR)

- Dedicated Terraform hosts for IdM server + replica (separate from UF VMs)
- Image Builder / Kickstart **pre-hardened** golden images (STIG at first boot)
- Satellite or Insights compliance policies as the enterprise evidence store
- Wire Splunk UF after STIG so audit logs ship centrally
- Map Zero Trust User/Device pillars in `zero-trust.md` to IdM HBAC + oscap timers

---

## 7. References

- DISA RHEL 9 STIG (STIG Viewer / DoD Cyber Exchange)
- Red Hat: [DISA STIG compliance](https://access.redhat.com/compliance/disa-stig)
- Red Hat: Using Ansible to install and manage Identity Management (RHEL 9)
- ComplianceAsCode / `scap-security-guide` STIG profile
- `RedHatOfficial.rhel9_stig` Ansible role (optional alternate remediator)
