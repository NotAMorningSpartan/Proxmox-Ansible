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
2. **RHEL cloud image** template on Proxmox (see [Creating the Proxmox Template](#creating-the-proxmox-template) below)
3. **Ansible control node** (see [Install Control Node Dependencies](#install-control-node-dependencies) below)
4. **Network connectivity** from the control node to both Proxmox and the new VM's IP range
5. **Red Hat credentials** — username/password or org ID + activation key
6. **IdM server** reachable from the VM's network (if IdM enrollment is desired)

### Install Control Node Dependencies

A Python virtual environment is **required** to avoid conflicts with system packages. The playbooks depend on several Python libraries (`proxmoxer`, `requests`, `netaddr`) and Ansible collections (`community.general`, `ansible.utils`) that may not be available system-wide.

```bash
# Create and activate the virtual environment
python3 -m venv ~/ansible-venv
source ~/ansible-venv/bin/activate

# Install Python dependencies
pip install ansible proxmoxer requests netaddr

# Install required Ansible collections
ansible-galaxy collection install community.general community.proxmox ansible.utils
```

Add the activation to your shell profile so it's always available:

```bash
echo 'source ~/ansible-venv/bin/activate' >> ~/.bashrc
```

> **Note:** The `community.proxmox` collection is the new home for Proxmox modules (migrated from `community.general`). Both are installed for compatibility.

### Creating the Proxmox Template

The playbooks clone VMs from a Proxmox template that has cloud-init pre-configured. The easiest approach is to use the official Red Hat KVM guest image.

#### Step 1: Download the RHEL Cloud Image

Download the KVM guest image from the Red Hat Customer Portal:
**Product Downloads > Red Hat Enterprise Linux > 10.x > KVM Guest Image** (`rhel-10.x-x86_64-kvm.qcow2`)

#### Step 2: Upload to Proxmox

Transfer the image to your Proxmox host:

```bash
scp rhel-10.1-x86_64-kvm.qcow2 root@your-proxmox-host:/var/lib/vz/template/qemu/
```

Or download directly on Proxmox (grab the authenticated URL from the Red Hat portal — it's tokenized and expires quickly):

```bash
mkdir -p /var/lib/vz/template/qemu
cd /var/lib/vz/template/qemu
wget "<paste-authenticated-url-here>"
```

You can also upload via the Proxmox web UI under **local storage > ISO Images** — it accepts any file type. The file will land in `/var/lib/vz/template/iso/`; adjust the import path accordingly.

#### Step 3: Create and Configure the Template

On the Proxmox host:

```bash
# Create the VM (use a high VMID like 9000 for templates)
qm create 9000 --name rhel10-cloudinit-template --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single

# Import the cloud image as the boot disk
qm set 9000 --scsi0 local-lvm:0,import-from=/var/lib/vz/template/qemu/rhel-10.1-x86_64-kvm.qcow2

# Add a cloud-init CD-ROM drive
qm set 9000 --ide2 local-lvm:cloudinit

# Set boot order to the imported disk
qm set 9000 --boot order=scsi0

# Set CPU type to 'host' (prevents kernel panics with cloud images)
qm set 9000 --cpu host

# Enable the QEMU guest agent
qm set 9000 --agent enabled=1

# Add serial console for web console access
qm set 9000 --serial0 socket --vga serial0

# Convert to template (prevents accidental boot)
qm template 9000
```

> **Important:** The `--cpu host` flag is critical. Cloud images often kernel panic with the default `kvm64` CPU type because they're compiled for modern instruction sets.

Replace `local-lvm` with your storage pool name (e.g., `hdd-pool`) if different.

After the import, you can delete the source qcow2 file — the disk data is now in your Proxmox storage:

```bash
rm /var/lib/vz/template/qemu/rhel-10.1-x86_64-kvm.qcow2
```

Verify the template looks correct:

```bash
qm config 9000
# Should show: scsi0 with the imported disk, ide2 with cloudinit,
# boot: order=scsi0, cpu: host, agent: enabled=1
```

#### Using a Standard RHEL ISO Instead

If you prefer to install from an ISO instead of the cloud image (more work, but full control):

```bash
# Boot the VM, install RHEL manually (minimal), then inside the guest:
dnf install cloud-init qemu-guest-agent
systemctl enable cloud-init cloud-init-local cloud-config cloud-final
systemctl enable qemu-guest-agent

# Clean up for templating
cloud-init clean
truncate -s 0 /etc/machine-id
rm -f /etc/ssh/ssh_host_*
dnf clean all
poweroff

# Then on the Proxmox host:
qm set 9000 --cpu host --agent enabled=1
qm template 9000
```

### Enabling Cloud-Init Snippets (for SSH Password Auth)

By default, Proxmox's built-in cloud-init parameters (`ciuser`/`cipassword`) create the user and set a password but **do not enable SSH password authentication**. The playbooks can upload a custom cloud-init user-data snippet that enables `ssh_pwauth: true`.

To use this feature, set `ci_use_custom_userdata: true` in your VM vars file. This requires "snippets" content type enabled on your Proxmox storage:

```bash
# On the Proxmox host — enable snippets on local storage
pvesm set local --content iso,vztmpl,snippets,backup

# Ensure the snippets directory exists
mkdir -p /var/lib/vz/snippets
```

Then in your VM vars file:

```yaml
ci_use_custom_userdata: true
```

Without this, only SSH key authentication will work for initial login. Set `admin_ssh_pubkey` in your vars file to your public key (`cat ~/.ssh/id_ed25519.pub`).

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
  - name: community.proxmox
    version: ">=1.0.0"
  - name: ansible.utils
    version: ">=2.0.0"
```

Install with:

```bash
ansible-galaxy collection install -r requirements.yml
```

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Failed to import proxmoxer` | Missing Python library | `pip install proxmoxer requests` (inside your venv) |
| `ipaddr filter failed` / `netaddr` error | Missing Python library | `pip install netaddr` |
| `ansible.utils.ipaddr` not found | Missing Ansible collection | `ansible-galaxy collection install ansible.utils` |
| VM kernel panics on boot | Default `kvm64` CPU type | Set `--cpu host` on the template: `qm set 9000 --cpu host` |
| VM boot loop "No bootable device" | Boot order not set | `qm set 9000 --boot order=scsi0` |
| SSH "Permission denied" (password) | Password auth not enabled | Set `ci_use_custom_userdata: true` and enable snippets on storage |
| SSH "Permission denied" (wrong user) | `ansible_user` not set | Ensure `admin_user` is defined in your vars file |
| `proxmox_api_host` not defined | Placeholder values in inventory | Edit `inventory/group_vars/proxmox.yml` and `inventory/hosts.yml` with real values |
| `pvesh: command not found` | SSH to Proxmox missing PATH | Fixed in role — uses API calls instead of CLI |
| `-e vars/file.yml` doesn't load | Missing `@` prefix | Use `-e @vars/file.yml` (the `@` tells Ansible to load from file) |
