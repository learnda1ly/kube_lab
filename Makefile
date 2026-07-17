.PHONY: help init plan apply ansible storage verify rebuild destroy \
	rhel9-init rhel9-plan rhel9-apply rhel9-ansible rhel9-destroy

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TF := terraform -chdir=$(ROOT)/terraform
TF_RHEL9 := terraform -chdir=$(ROOT)/terraform/rhel9
INV := $(ROOT)/ansible/inventory/hosts.proxmox.yml
INV_RHEL9 := $(ROOT)/ansible/inventory/hosts.rhel9.yml
ANSIBLE := ANSIBLE_CONFIG=$(ROOT)/ansible/ansible.cfg ansible-playbook -i $(INV)
ANSIBLE_RHEL9 := ANSIBLE_CONFIG=$(ROOT)/ansible/ansible.cfg ansible-playbook -i $(INV_RHEL9)

# Optional extra ansible-playbook args: make rhel9-ansible EXTRA='-e splunk_uf_version=9.3.2-...'
EXTRA ?=

# Source gitignored .env when present (PROXMOX_VE_API_TOKEN, ANSIBLE_*).
define with_env
bash -c 'set -a; [ -f "$(ROOT)/.env" ] && . "$(ROOT)/.env"; set +a; $(1)'
endef

help:
	@echo "Targets (k3s lab):"
	@echo "  make init      - terraform init + ansible galaxy collections"
	@echo "  make plan      - terraform plan (sources .env if present)"
	@echo "  make apply     - terraform apply (sources .env if present)"
	@echo "  make ansible   - run site playbook against generated inventory"
	@echo "  make storage   - (re)install NFS StorageClass provisioner only"
	@echo "  make verify    - cluster + NFS export readiness check"
	@echo "  make rebuild   - full recreate (terraform apply + ansible + verify)"
	@echo "  make destroy   - terraform destroy (prompted)"
	@echo ""
	@echo "Targets (RHEL 9 Splunk UF lab — separate state/inventory):"
	@echo "  make rhel9-init     - terraform init for terraform/rhel9"
	@echo "  make rhel9-plan     - plan 3x RHEL 9 UF VMs"
	@echo "  make rhel9-apply    - apply RHEL 9 VMs + write hosts.rhel9.yml"
	@echo "  make rhel9-ansible  - install/upgrade Splunk UF on rhel9_uf group"
	@echo "  make rhel9-destroy  - destroy RHEL 9 VMs only (k3s untouched)"
	@echo "  EXTRA='...'         - extra ansible-playbook args for rhel9-ansible"

init:
	$(call with_env,$(TF) init -upgrade)
	ansible-galaxy collection install -r $(ROOT)/ansible/requirements.yml

plan:
	$(call with_env,$(TF) plan)

apply:
	$(call with_env,$(TF) apply)

ansible:
	$(call with_env,$(ANSIBLE) $(ROOT)/ansible/playbooks/site.yml)

storage:
	$(call with_env,$(ANSIBLE) $(ROOT)/ansible/playbooks/storage.yml)

verify:
	$(call with_env,$(ANSIBLE) $(ROOT)/ansible/playbooks/verify.yml)

rebuild:
	$(ROOT)/scripts/rebuild.sh

destroy:
	$(ROOT)/scripts/destroy.sh

rhel9-init:
	$(call with_env,$(TF_RHEL9) init -upgrade)

rhel9-plan:
	$(call with_env,$(TF_RHEL9) plan)

rhel9-apply:
	$(call with_env,$(TF_RHEL9) apply)

rhel9-ansible:
	$(call with_env,$(ANSIBLE_RHEL9) $(ROOT)/ansible/playbooks/splunk_uf.yml $(EXTRA))

rhel9-destroy:
	$(call with_env,$(TF_RHEL9) destroy)
