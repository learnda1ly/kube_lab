.PHONY: help init plan apply ansible verify rebuild destroy

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TF := terraform -chdir=$(ROOT)/terraform
INV := $(ROOT)/ansible/inventory/hosts.proxmox.yml

help:
	@echo "Targets:"
	@echo "  make init      - terraform init + ansible galaxy collections"
	@echo "  make plan      - terraform plan"
	@echo "  make apply     - terraform apply (creates VMs + inventory)"
	@echo "  make ansible   - run site playbook against generated inventory"
	@echo "  make verify    - kubectl readiness check via Ansible"
	@echo "  make rebuild   - full recreate (terraform apply + ansible + verify)"
	@echo "  make destroy   - terraform destroy (prompted)"

init:
	$(TF) init -upgrade
	ansible-galaxy collection install -r $(ROOT)/ansible/requirements.yml

plan:
	$(TF) plan

apply:
	$(TF) apply

ansible:
	ansible-playbook -i $(INV) $(ROOT)/ansible/playbooks/site.yml

verify:
	ansible-playbook -i $(INV) $(ROOT)/ansible/playbooks/verify.yml

rebuild:
	$(ROOT)/scripts/rebuild.sh

destroy:
	$(ROOT)/scripts/destroy.sh