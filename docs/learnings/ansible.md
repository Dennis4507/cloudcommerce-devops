# Ansible — Deep Dive

## What is Ansible?

Ansible is a configuration management tool. Where Terraform answers "what infrastructure exists in AWS?", Ansible answers "what is installed and running on each server?".

The core difference from other config management tools (Chef, Puppet, SaltStack) is that Ansible is **agentless**. There is nothing to install on the servers you manage. Ansible connects over standard SSH, runs tasks, and disconnects. The target servers don't know Ansible exists — they just see SSH connections.

```
Your Machine (Control Node)
        │
        │ SSH
        ▼
Jenkins Server → runs tasks → disconnects
k3s Server     → runs tasks → disconnects
```

## Why Agentless Matters

Agent-based tools require you to install and maintain a daemon on every server you manage. That daemon:
- Must be kept updated across all servers
- Consumes memory and CPU constantly
- Can fail and leave the server in an unmanageable state
- Is another attack surface

Ansible has none of these problems. If a server has SSH and Python (standard on every Linux server), Ansible can manage it.

## The Control Node

The machine you run Ansible from is called the control node. For this project, the control node is WSL (Windows Subsystem for Linux) running Ubuntu 22.04 on the local machine.

**Why WSL?** Ansible does not run natively on Windows. WSL provides a real Linux environment on Windows without a full virtual machine. Every Ansible command is run from inside WSL.

**Why pip over apt for Ansible?** Ubuntu's packaged Ansible (`apt install ansible`) is often several versions behind. pip installs the current release directly from the Ansible project, ensuring access to the latest modules and bug fixes.

```bash
pip install ansible
```

## Inventory — Telling Ansible What to Manage

The inventory file lists all the servers Ansible manages, organised into groups:

```ini
[jenkins]
3.127.90.169

[k3s]
63.184.235.88

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/cloudcommerce-dev-key
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```

Groups (`[jenkins]`, `[k3s]`) let you target specific subsets of servers in playbooks. `[all:vars]` sets variables that apply to every server — the SSH user and key path.

## ansible.cfg — The Configuration File

`ansible.cfg` stores default settings so you don't repeat them on every command:

```ini
[defaults]
inventory       = inventory/hosts
remote_user     = ubuntu
private_key_file = ~/.ssh/cloudcommerce-dev-key
host_key_checking = False
```

**The WSL world-writable problem:** Ansible refuses to auto-load `ansible.cfg` from world-writable directories. WSL mounts the Windows filesystem at `/mnt/c/` with world-writable permissions — so any `ansible.cfg` sitting in a project directory there is silently ignored.

The error you see:
```
[WARNING]: Ansible is being run in a world writable directory, ignoring it as an ansible.cfg source.
[WARNING]: provided hosts list is empty, only localhost is available.
```

**Why this security rule exists:** On a shared system, a malicious `ansible.cfg` in a world-writable directory could inject configuration — changing the remote user, pointing at a rogue inventory, or disabling host key checking — without the operator knowing.

**Fix:** Pass all required settings explicitly on every command rather than relying on auto-loading:

```bash
ansible all -i inventory/hosts -m ping --private-key ~/.ssh/cloudcommerce-dev-key -u ubuntu
ansible-playbook -i inventory/hosts playbooks/setup-jenkins.yml --private-key ~/.ssh/cloudcommerce-dev-key -u ubuntu
```

This bypasses the restriction entirely and is the approach used throughout this project.

## Idempotency — Run It Twice, Get the Same Result

The most important property of Ansible tasks is idempotency. Running a playbook twice produces the same result as running it once — it doesn't duplicate work or break things.

```
Task: "ensure the Jenkins package is installed"
  → First run:  package not present → installs it  (changed)
  → Second run: package already present → skips it (ok)

Result: identical state after both runs
```

Every task in a well-written Ansible playbook checks the current state before acting. The `apt` module checks if a package is installed before installing. The `systemd` module checks if a service is running before starting. The `user` module checks if a user is in a group before adding them.

In Ansible output, `ok` means "already in desired state, no action taken" and `changed` means "action was taken to reach desired state". Both are success states. `failed` means the task could not reach the desired state.

## Playbooks — The Automation Script

A playbook is a YAML file describing a sequence of tasks to run on a group of servers:

```yaml
---
- name: Install and configure Jenkins
  hosts: jenkins        # run on servers in [jenkins] group
  become: true          # run as root (sudo)

  tasks:
    - name: Install Java 21
      apt:
        name: openjdk-21-jdk
        state: present
        update_cache: yes
```

**`become: true`** — escalates to root (equivalent to `sudo`). Most server configuration tasks require root access.

**`hosts:`** — targets the task at a specific group from the inventory. `hosts: all` runs on every server; `hosts: jenkins` runs only on servers in the `[jenkins]` group.

## Key Ansible Modules

Modules are the building blocks of tasks. Each module knows how to manage a specific type of resource:

| Module | What It Does |
|--------|-------------|
| `apt` | Install/remove packages on Debian/Ubuntu |
| `shell` | Run a shell command with full shell features |
| `command` | Run a command (no shell features like pipes) |
| `systemd` | Start/stop/enable/disable services |
| `user` | Manage Linux user accounts and group membership |
| `wait_for` | Pause until a port becomes available |
| `debug` | Print a message or variable to the terminal |

## Shell Module — `args.creates` for Idempotency

The `shell` module runs arbitrary shell commands, but shell commands are not inherently idempotent. The `creates` argument makes them so:

```yaml
- name: Import Jenkins GPG key from keyserver
  shell: |
    gpg --no-default-keyring \
        --keyring /usr/share/keyrings/jenkins-keyring.gpg \
        --keyserver keyserver.ubuntu.com \
        --recv-keys 7198F4B714ABFC68
    chmod 644 /usr/share/keyrings/jenkins-keyring.gpg
  args:
    creates: /usr/share/keyrings/jenkins-keyring.gpg
```

`creates: /path/to/file` tells Ansible: "skip this task if this file already exists". So the GPG import only runs the first time — on subsequent playbook runs, the key file is already there and the task is skipped.

## register and debug — Capturing and Printing Output

`register` saves a task's output to a variable. `debug` prints it:

```yaml
- name: Get Jenkins initial admin password
  command: cat /var/lib/jenkins/secrets/initialAdminPassword
  register: jenkins_password
  changed_when: false     # reading a file doesn't change anything

- name: Print Jenkins initial admin password
  debug:
    msg: "Jenkins initial admin password: {{ jenkins_password.stdout }}"
```

`changed_when: false` prevents Ansible from marking a read-only operation as `changed`. Without it, every playbook run would show this task as making a change — misleading because reading a file changes nothing.

## Testing Connectivity — The Ping Module

Before running any playbook, verify Ansible can reach all servers:

```bash
ansible all -i inventory/hosts -m ping --private-key ~/.ssh/cloudcommerce-dev-key -u ubuntu
```

A successful response:
```
3.127.90.169 | SUCCESS => {"ping": "pong"}
63.184.235.88 | SUCCESS => {"ping": "pong"}
```

The Ansible `ping` module is not ICMP ping — it SSHes into the server and verifies Python is available. If this succeeds, playbooks will work.

## Reading Playbook Output

A successful playbook run:
```
PLAY RECAP
3.127.90.169 : ok=12  changed=5  unreachable=0  failed=0
```

- `ok` — tasks that found the server already in the desired state
- `changed` — tasks that made changes to reach the desired state
- `unreachable` — servers that couldn't be SSH'd into
- `failed` — tasks that could not complete

`failed=0` is the goal. `ok=12, changed=0` on a second run means the playbook is fully idempotent.

## SSH Key Setup for Ansible on WSL

The private key must be in the WSL filesystem (not `/mnt/c/`) with permissions `600`:

```bash
cp /mnt/c/Users/OnlyM/Devops\ Project/cloudcommerce-devops/terraform/keys/cloudcommerce-dev-key ~/.ssh/
chmod 600 ~/.ssh/cloudcommerce-dev-key
```

SSH refuses to use private keys that are readable by other users (`chmod 644` or looser). This is a hard security requirement — not a warning.

## Interview Talking Points

- "I use Ansible for server configuration because it's agentless — there's nothing to install or maintain on target servers, which reduces attack surface and operational overhead"
- "All Ansible playbooks are idempotent — running them twice produces the same result as running them once, which makes them safe to re-run after partial failures"
- "I ran Ansible from WSL because it doesn't support Windows natively — the world-writable filesystem restriction required passing all config explicitly on the command line rather than relying on ansible.cfg auto-loading"
- "I use the `creates` argument on shell tasks to make them idempotent — the task is skipped if the target file already exists"
- "I always test connectivity with `ansible all -m ping` before running playbooks — this catches SSH or inventory issues before a long playbook run fails partway through"
