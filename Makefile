# Makefile for Proxmox RHEL VM provisioning
#
# Usage:
#   make full       VM=webserver01     # Provision + configure
#   make provision  VM=webserver01     # Phase 1 only
#   make configure  VM=webserver01     # Phase 2 only
#   make validate   VM=webserver01     # Run validation checks
#   make teardown   VM=webserver01     # Destroy VM (requires confirmation)
#   make fleet     FLEET=fleet-example  # Provision + configure a fleet
#   make lint                          # Run ansible-lint

VAULT_FILE   ?= vault/secrets.yml
VAULT_ARGS   ?= --ask-vault-pass

# Require VM= for single-VM targets
check-vm:
ifndef VM
	$(error VM is not set. Usage: make <target> VM=<vmname>)
endif

# Require FLEET= for fleet target
check-fleet:
ifndef FLEET
	$(error FLEET is not set. Usage: make fleet FLEET=<fleet-name>)
endif

.PHONY: full provision configure validate teardown fleet lint check-vm check-fleet

full: check-vm
	ansible-playbook playbooks/site.yml \
		-e @vars/$(VM).yml \
		-e @$(VAULT_FILE) \
		$(VAULT_ARGS)

provision: check-vm
	ansible-playbook playbooks/provision.yml \
		-e @vars/$(VM).yml \
		-e @$(VAULT_FILE) \
		$(VAULT_ARGS)

configure: check-vm
	ansible-playbook playbooks/configure.yml \
		-e @vars/$(VM).yml \
		-e @$(VAULT_FILE) \
		$(VAULT_ARGS)

validate: check-vm
	ansible-playbook playbooks/validate.yml \
		-i "$$(grep vm_ip vars/$(VM).yml | head -1 | awk -F'\"' '{print $$2}' | cut -d/ -f1)," \
		-e @vars/$(VM).yml \
		$(VAULT_ARGS)

teardown: check-vm
	@echo "WARNING: This will DESTROY VM '$(VM)' on Proxmox."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1)
	ansible-playbook playbooks/teardown.yml \
		-i "$$(grep vm_ip vars/$(VM).yml | head -1 | awk -F'\"' '{print $$2}' | cut -d/ -f1)," \
		-e @vars/$(VM).yml \
		-e @$(VAULT_FILE) \
		-e confirm_destroy=true \
		$(VAULT_ARGS)

fleet: check-fleet
	ansible-playbook playbooks/fleet.yml \
		-e @vars/$(FLEET).yml \
		-e @$(VAULT_FILE) \
		$(VAULT_ARGS)

lint:
	ansible-lint playbooks/ roles/
