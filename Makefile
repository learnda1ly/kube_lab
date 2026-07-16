.PHONY: help init plan apply ansible storage verify rebuild destroy

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TF := terraform -chdir=$(ROOT)/terraform
INV := $(ROOT)/ansible/inventory/hosts.proxmox.yml
ANSIBLE := ANSIBLE_CONFIG=$(ROOT)/ansible/ansible.cfg ansible-playbook -i $(INV)

# Source gitignored .env when present (PROXMOX_VE_API_TOKEN, ANSIBLE_*).
define with_env
bash -c 'set -a; [ -f "$(ROOT)/.env" ] && . "$(ROOT)/.env"; set +a; $(1)'
endef

help:
	@echo "Targets:"
	@echo "  make init      - terraform init + ansible galaxy collections"
	@echo "  make plan      - terraform plan (sources .env if present)"
	@echo "  make apply     - terraform apply (sources .env if present)"
	@echo "  make ansible   - run site playbook against generated inventory"
	@echo "  make storage   - (re)install NFS StorageClass provisioner only"
	@echo "  make verify    - cluster + NFS export readiness check"
	@echo "  make rebuild   - full recreate (terraform apply + ansible + verify)"
	@echo "  make destroy   - terraform destroy (prompted)"

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
