# Ansible Playbooks for RHEL VM Provisioning on Proxmox

Modular, variable-driven Ansible playbooks that provision RHEL virtual machines on Proxmox VE with complete day-1 configuration. Every aspect — networking, storage, users, packages, subscription registration, and identity enrollment — is controlled through variables so each VM can be customized at runtime.

## Architecture

The project uses a two-phase approach:

| Phase | Mechanism | What It Handles |
|-------|-----------|-----------------|
| **Phase 1 — Provisioning** | Ansible -> Proxmox API | Clone template, cloud-init config (network, users, hostname), resize disk, start VM |
| **Phase 2 — Day-1 Config** | Ansible -> SSH into VM | RHSM registration, package installation, kdump, timezone, IdM enrollment |

Cloud-init handles items that must exist at first boot (static IP, hostname, user accounts). Everything else requires a running, network-reachable system, so Ansible connects over SSH after the VM is up.

## Prerequisites

1. **Proxmox VE** with an API token created for Ansible (Datacenter > Permissions > API Tokens)
2. **RHEL cloud image** template on Proxmox — import the qcow2, attach a cloud-init drive, convert to template
3. **Ansible control node** with:
   - `ansible-core` 2.14+
   - `community.general` collection
   - `proxmoxer` and `requests` Python libraries
4. **Network connectivity** from the control node to both Proxmox and the new VM's IP range
5. **Red Hat credentials** — username/password or org ID + activation key
6. **IdM server** reachable from the VM's network (if IdM enrollment is desired)

### Install Dependencies

```bash
ansible-galaxy collection install community.general
pip install proxmoxer requests
```

## Quick Start

```bash
# 1. Set up vault secrets
cp vault/secrets.yml.example vault/secrets.yml
# Edit vault/secrets.yml with real values
ansible-vault encrypt vault/secrets.yml

# 2. Create a VM variable file
cp vars/example-vm.yml vars/webserver01.yml
# Edit vars/webserver01.yml with your VM details

# 3. Update inventory/hosts.yml with your Proxmox host

# 4. Run the full pipeline
ansible-playbook playbooks/site.yml \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  --ask-vault-pass
```

## Usage Examples

### Single VM — full provision + configure

```bash
ansible-playbook playbooks/site.yml \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  --ask-vault-pass
```

### Provision only (Phase 1 — no day-1 config)

```bash
ansible-playbook playbooks/provision.yml \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  --ask-vault-pass
```

### Configure only (Phase 2 — VM already exists)

```bash
ansible-playbook playbooks/configure.yml \
  -i "192.168.1.101," \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  --ask-vault-pass
```

### VM without IdM enrollment

```bash
ansible-playbook playbooks/site.yml \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  -e idm_enroll=false \
  --ask-vault-pass
```

### Fleet provisioning (multiple VMs in one run)

Define VMs in a fleet vars file (see `vars/fleet-example.yml`), then run:

```bash
make fleet FLEET=fleet-example

# Or directly:
ansible-playbook playbooks/fleet.yml \
  -e @vars/fleet-example.yml \
  -e @vault/secrets.yml \
  --ask-vault-pass
```

Provisioning runs serially (one VM at a time for Proxmox API safety). Configuration runs in parallel across all VMs.

### Multiple VMs with separate var files

```bash
# Alternative: provision each VM individually in sequence
for vm in webserver01 webserver02 dbserver01; do
  ansible-playbook playbooks/site.yml \
    -e @vars/${vm}.yml \
    -e @vault/secrets.yml \
    --ask-vault-pass
done
```

### Dry run (check mode)

```bash
ansible-playbook playbooks/site.yml \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  --check --diff \
  --ask-vault-pass
```

### Run specific tags only

```bash
# Only RHSM registration
ansible-playbook playbooks/configure.yml \
  -i "192.168.1.101," \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  --tags rhsm \
  --ask-vault-pass

# Only package installation
ansible-playbook playbooks/configure.yml \
  -i "192.168.1.101," \
  -e @vars/webserver01.yml \
  --tags packages
```

## Project Structure

```
├── ansible.cfg                              # Ansible configuration
├── inventory/
│   ├── hosts.yml                            # Static inventory (Proxmox host)
│   └── group_vars/
│       ├── all.yml                          # Global defaults
│       ├── proxmox.yml                      # Proxmox API connection
│       └── newvms.yml                       # SSH defaults for new VMs
├── roles/
│   ├── proxmox_provision/                   # Clone template, cloud-init, start VM
│   │   ├── tasks/main.yml
│   │   ├── defaults/main.yml
│   │   └── templates/cloud-init-user-data.yml.j2
│   ├── wait_for_vm/                         # Wait for SSH availability
│   │   └── tasks/main.yml
│   ├── rhsm_register/                       # RHSM registration and repos
│   │   ├── tasks/main.yml
│   │   ├── defaults/main.yml
│   │   └── handlers/main.yml
│   ├── base_config/                         # Timezone, kdump, packages
│   │   ├── tasks/main.yml
│   │   └── defaults/main.yml
│   └── idm_enroll/                          # IdM/FreeIPA enrollment
│       ├── tasks/main.yml
│       └── defaults/main.yml
├── playbooks/
│   ├── site.yml                             # Master playbook (Phase 1 + 2)
│   ├── provision.yml                        # Phase 1 only
│   ├── configure.yml                        # Phase 2 only
│   ├── validate.yml                         # Post-deployment validation
│   ├── teardown.yml                         # Destroy VM and clean up
│   ├── fleet.yml                            # Multi-VM fleet provisioning
│   └── fleet_provision_vm.yml               # Included tasks for fleet.yml
├── vars/
│   ├── example-vm.yml                       # Example single-VM variable file
│   └── fleet-example.yml                    # Example fleet variable file
└── vault/
    └── secrets.yml.example                  # Vault secrets template
```

## Roles

| Role | Description | Tags |
|------|-------------|------|
| `proxmox_provision` | Clones Proxmox template, configures cloud-init, resizes disk, starts VM | `provision` |
| `wait_for_vm` | Waits for SSH on the new VM, pauses for cloud-init to finish | `wait` |
| `rhsm_register` | Registers with Red Hat, enables repos, optionally pins release | `rhsm` |
| `base_config` | Sets timezone, disables kdump, installs packages, runs updates | `timezone`, `kdump`, `packages` |
| `idm_enroll` | Enrolls VM in Red Hat IdM via DNS autodiscovery, verifies chronyd | `idm` |

## Variable Reference

### Proxmox Connection

Set in `inventory/group_vars/proxmox.yml`. Token secret in vault.

| Variable | Description | Example |
|----------|-------------|---------|
| `proxmox_api_host` | Proxmox VE hostname/IP | `pve01.example.com` |
| `proxmox_api_user` | API user | `root@pam` |
| `proxmox_api_token_id` | API token name | `ansible` |
| `proxmox_api_token_secret` | API token secret | (vaulted) |
| `proxmox_node` | Target Proxmox node | `pve01` |

### VM Specifications

Set per-VM in `vars/<vmname>.yml`.

| Variable | Description | Default |
|----------|-------------|---------|
| `vm_name` | VM FQDN hostname | (required) |
| `vm_id` | Proxmox VMID (0 = auto) | `0` |
| `vm_template` | Template to clone | `rhel10-cloudinit-template` |
| `vm_cores` | CPU cores | `2` |
| `vm_memory` | RAM in MB | `4096` |
| `vm_disk_size` | Root disk size | `40G` |
| `vm_storage` | Proxmox storage pool | `local-lvm` |
| `vm_network_bridge` | Network bridge | `vmbr0` |
| `vm_vlan_tag` | VLAN tag (empty = untagged) | `""` |
| `vm_start_on_create` | Start VM after provisioning | `true` |

### Network (Cloud-Init)

| Variable | Description | Example |
|----------|-------------|---------|
| `vm_ip` | Static IP with CIDR | `192.168.1.101/24` |
| `vm_gateway` | Default gateway | `192.168.1.1` |
| `vm_dns_servers` | DNS server list | `["192.168.1.10"]` |
| `vm_dns_domain` | Search domain | `example.com` |

### User Accounts (Cloud-Init)

| Variable | Description | Default |
|----------|-------------|---------|
| `admin_user` | Admin username | `sysadmin` |
| `admin_password` | Admin password | (vaulted) |
| `root_password` | Root password | (vaulted) |
| `admin_ssh_pubkey` | SSH public key for admin | `""` |

### Red Hat Subscription Manager

| Variable | Description | Default |
|----------|-------------|---------|
| `rhsm_username` | Portal username (Mode 1) | (vaulted) |
| `rhsm_password` | Portal password (Mode 1) | (vaulted) |
| `rhsm_org_id` | Org ID (Mode 2) | `""` |
| `rhsm_activation_key` | Activation key (Mode 2) | `""` |
| `rhsm_repos` | Repos to enable | `[baseos, appstream]` |
| `rhsm_release_version` | Pin minor version (e.g. "9.4") | `""` |
| `rhsm_force_register` | Force re-registration | `false` |

### Base Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `timezone` | System timezone | `America/Denver` |
| `kdump_enabled` | Keep kdump enabled | `false` |
| `base_package_group` | DNF group to install | `@server` |
| `extra_packages` | Additional packages | `[vim, plocate, ipa-client, wget]` |
| `dnf_update` | Run full system update | `true` |

### IdM / FreeIPA Enrollment

The VM's DNS is pointed at the IdM server during provisioning so `ipa-client-install` autodiscovers server/domain/realm via DNS SRV records. Flags like `--server`, `--domain`, and `--realm` are intentionally not used.

| Variable | Description | Default |
|----------|-------------|---------|
| `idm_enroll` | Master toggle for IdM enrollment | `true` |
| `idm_domain` | Domain for DNS prereq check only | `example.com` |
| `idm_admin_principal` | Enrollment principal | `admin` |
| `idm_admin_password` | Enrollment password | (vaulted) |
| `idm_ntp_pool` | NTP pool for `--ntp-pool` | `pool.ntp.org` |

### Vault Secrets

All sensitive values live in `vault/secrets.yml`. See `vault/secrets.yml.example` for the template.

| Variable | Used By |
|----------|---------|
| `vault_proxmox_api_token_secret` | Proxmox API authentication |
| `root_password` | Cloud-init root account |
| `admin_password` | Cloud-init admin account |
| `rhsm_username` | RHSM Mode 1 |
| `rhsm_password` | RHSM Mode 1 |
| `idm_admin_password` | IdM enrollment |

## Validation & Teardown

### Validate a provisioned VM

Runs 9 checks (RHSM, repos, kdump, timezone, packages, IdM, chronyd, sudo, IP) and prints a pass/fail summary.

```bash
make validate VM=webserver01

# Or directly:
ansible-playbook playbooks/validate.yml \
  -i "192.168.1.101," \
  -e @vars/webserver01.yml
```

### Tear down a VM

Unregisters from RHSM, unenrolls from IdM, then stops and destroys the VM on Proxmox. Requires explicit confirmation.

```bash
make teardown VM=webserver01

# Or directly:
ansible-playbook playbooks/teardown.yml \
  -i "192.168.1.101," \
  -e @vars/webserver01.yml \
  -e @vault/secrets.yml \
  -e confirm_destroy=true \
  --ask-vault-pass
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make full VM=<name>` | Full provision + configure pipeline |
| `make provision VM=<name>` | Phase 1 only (Proxmox provisioning) |
| `make configure VM=<name>` | Phase 2 only (day-1 configuration) |
| `make validate VM=<name>` | Run validation checks on a VM |
| `make teardown VM=<name>` | Destroy VM (interactive confirmation) |
| `make fleet FLEET=<name>` | Provision + configure a fleet of VMs |
| `make lint` | Run ansible-lint on playbooks and roles |

Override the vault file path or args: `make full VM=webserver01 VAULT_FILE=vault/prod.yml`

## Vault Workflow

```bash
# Create from template
cp vault/secrets.yml.example vault/secrets.yml

# Edit with real values
vim vault/secrets.yml

# Encrypt
ansible-vault encrypt vault/secrets.yml

# Edit encrypted file later
ansible-vault edit vault/secrets.yml

# Run playbooks with vault
ansible-playbook playbooks/site.yml \
  -e @vars/myvm.yml \
  -e @vault/secrets.yml \
  --ask-vault-pass
```

## Pin Collections

Create a `requirements.yml` to pin dependency versions:

```yaml
collections:
  - name: community.general
    version: ">=9.0.0"
```

Install with:

```bash
ansible-galaxy collection install -r requirements.yml
```
