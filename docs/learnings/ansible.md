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

## Modules vs Shell — When to Use Each

This is one of the most important Ansible concepts to understand.

**Built-in modules** are Ansible's preferred way to run tasks. Ansible fully controls them:
- Knows exactly what state was before and after
- Reports `ok` vs `changed` accurately
- Handles errors cleanly
- Are idempotent by design

```yaml
- name: Install packages         ← Ansible module
  apt:
    name: jenkins
    state: present               # Ansible checks, installs only if missing, fails if it can't

- name: Start service            ← Ansible module
  systemd:
    name: jenkins
    state: started               # Ansible checks service state before acting
```

**The `shell` module** hands Ansible a bash script and says "run this." Ansible only sees the final exit code — it has no visibility into what happened inside:

```yaml
- name: Install AWS CLI          ← shell task
  shell: |
    curl ...      # Ansible doesn't know if this worked
    unzip ...     # Ansible doesn't know if this worked
    ./install     # Ansible doesn't know if this worked
    rm -rf ...    # this always works — exit code 0
                  # Ansible sees 0 → reports "changed" ✓ (even if curl failed)
```

**Rule:** Use built-in modules wherever one exists. Use `shell` only when no module covers what you need. There are over 3,000 Ansible modules — always check first.

## The Silent Failure Problem with Shell Tasks

The AWS CLI installation in this project exposed a critical shell task pitfall.

The install script requires `unzip` to extract the downloaded zip file. `unzip` was not installed. The extraction step failed silently — but the final `rm -rf` always succeeds (exit 0), so Ansible reported `changed` (success). The binary was never created.

This was only caught by SSHing into the server and running `aws --version` — which returned command not found despite Ansible claiming success.

**The three fixes:**

**1 — Install dependencies first:**
```yaml
- name: Install Java 21 and dependencies
  apt:
    name:
      - openjdk-21-jdk
      - curl
      - gnupg
      - unzip          ← added: required by AWS CLI install script
```

**2 — Add `set -e` to shell scripts:**
```yaml
- name: Install AWS CLI
  shell: |
    set -e             ← if ANY command fails, stop immediately
    curl "..." -o /tmp/awscliv2.zip
    unzip ...          ← now fails loudly if unzip missing
    /tmp/aws/install
    rm -rf ...
```

`set -e` is bash's "stop on error" flag. Without it, bash continues executing after a failed command. With it, the first failure stops the script and returns a non-zero exit code — which Ansible correctly marks as `failed`.

**3 — Clean up before retrying:**
```yaml
- name: Clean up any partial AWS CLI install
  file:
    path: "{{ item }}"
    state: absent
  loop:
    - /tmp/awscliv2.zip
    - /tmp/aws
```

A failed install may leave partial files. Without cleanup, the `creates: /usr/local/bin/aws` check would see the zip still present and behave unpredictably. The `file` module with `state: absent` is idempotent — it removes the files if they exist, does nothing if they don't.

## failed_when and changed_when — Controlling Task Outcomes

Two important task-level controls:

**`changed_when: false`** — tell Ansible this task never makes changes, even if it runs:
```yaml
- name: Get Jenkins initial admin password
  command: cat /var/lib/jenkins/secrets/initialAdminPassword
  register: jenkins_password
  changed_when: false     ← reading a file changes nothing, don't mark as changed
```

Without this, every read-only operation would show as `changed` — misleading in the PLAY RECAP.

**`failed_when: false`** — tell Ansible never to fail this task, regardless of exit code:
```yaml
- name: Get Jenkins initial admin password
  command: cat /var/lib/jenkins/secrets/initialAdminPassword
  register: jenkins_password
  changed_when: false
  failed_when: false      ← file not found (rc=1) is acceptable after first setup
```

The initial admin password file only exists on first-time Jenkins setup. Once you've created an admin account it's deleted. Without `failed_when: false`, every subsequent playbook run would crash at this task with "No such file or directory".

`failed_when` accepts conditions:
```yaml
failed_when: result.rc != 0 and 'already exists' not in result.stderr
# fail only if the return code is non-zero AND the error is not "already exists"
```

## Memory Constraints on t2.micro

The Jenkins EC2 instance is a t2.micro with 1GB RAM and no swap. Jenkins JVM consumes ~600MB leaving only ~100MB available at runtime.

Running system maintenance (apt installs, large downloads) while Jenkins is running causes operations to fail or hang — there is simply not enough memory for new processes to start.

**The pattern for any system maintenance on the Jenkins server:**
```bash
sudo systemctl stop jenkins    # free ~400-500MB
# run maintenance (Ansible playbook, manual installs, etc.)
sudo systemctl start jenkins   # or the playbook starts it automatically
```

This is not a flaw — it's an expected operational pattern for memory-constrained servers. In a production environment, a larger instance type would be used. For this portfolio project, the t2.micro constraint is understood and managed.

**Why no swap?** The EC2 instance was provisioned without a swap file. Adding swap would give the OS breathing room when RAM is under pressure. This is a future improvement — for now, stopping Jenkins before maintenance is the established pattern.

## SSH Key Permissions — 600 vs 777

SSH private keys must have permissions `600` (readable only by the owner):

```bash
chmod 600 ~/.ssh/cloudcommerce-dev-key
```

Files on the Windows filesystem mounted in WSL (`/mnt/c/...`) appear with permissions `777` — readable by everyone — because Windows doesn't have the same permission model as Linux. SSH refuses to use any private key that is world-readable:

```
WARNING: UNPROTECTED PRIVATE KEY FILE!
Permissions 0777 for '/mnt/c/...cloudcommerce-dev-key' are too open.
```

**The fix:** Always use the key from the WSL home directory (`~/.ssh/`), not from the Windows path. The key was copied there during initial setup with the correct permissions:

```bash
cp /mnt/c/Users/OnlyM/.../cloudcommerce-dev-key ~/.ssh/
chmod 600 ~/.ssh/cloudcommerce-dev-key
```

## GPG Keys — How Ubuntu Verifies Third-Party Software

When Ubuntu installs software from a third-party source (like Jenkins), it does not just download and install it blindly. It first checks a digital signature — called a GPG key — to verify that the software genuinely came from Jenkins and has not been tampered with. Think of it like a wax seal on a letter: before opening it, you check the seal matches the sender.

Every apt repository has a release file that is signed with a specific GPG key. Ubuntu's apt looks at that signature, then searches its trusted keyring for the matching key. If it finds a match — trusted. If not — rejected.

```
Jenkins Repository
  └── Release file (signed with key ID: 7198F4B714ABFC68)
          │
          ▼
Ubuntu apt checks trusted keyring for key 7198F4B714ABFC68
  └── Found? → Install allowed
  └── Not found? → "NO_PUBKEY 7198F4B714ABFC68" error
```

## The Jenkins GPG Key Incident — A Real Debugging Session

During the Jenkins reinstallation after the Terraform AMI incident, the Ansible playbook failed four times with the same error:

```
NO_PUBKEY 7198F4B714ABFC68
E:The repository 'https://pkg.jenkins.io/debian-stable binary/ Release' is not signed.
```

**Why the original server never had this problem:** The original playbook used the older `apt-key` approach which was less strict about key format and placement. The newer Ubuntu AMI (after the AMI incident) has a stricter version of apt that enforces exact key ID matching. Same principle, tighter enforcement.

**Attempt 1 — keyserver with custom keyring:**
```bash
gpg --keyring /usr/share/keyrings/jenkins-keyring.gpg \
    --keyserver keyserver.ubuntu.com --recv-keys 7198F4B714ABFC68
```
The key was stored in a custom keyring file but in the wrong binary format for apt's `signed-by` directive. The key existed but apt could not read it.

**Attempt 2 — reordered tasks:**
The key import and repository tasks were moved before the Java install task. This fixed the ordering but not the key format. Same error.

**Attempt 3 — downloaded from Jenkins website:**
```bash
wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
```
The `jenkins.io-2023.key` file was downloaded and saved directly. But this file contains a **different key ID** than `7198F4B714ABFC68`. The Jenkins stable repository is signed with one key; the 2023 key file contains a different one. Presenting the wrong key to apt still fails.

**Attempt 4 — downloaded and converted:**
```bash
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
```
Same wrong key, different format. Still no match.

**The fix — fetch the exact key by its ID:**
```bash
gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 7198F4B714ABFC68
gpg --batch --export --armor 7198F4B714ABFC68 > /usr/share/keyrings/jenkins-keyring.asc
```
Instead of guessing which file contained the right key, we told the keyserver: "give me exactly key `7198F4B714ABFC68`." That key is exactly what the Jenkins stable repository was signed with. Ubuntu checked it, found a match, and allowed the installation.

**The lesson:** When apt reports `NO_PUBKEY XXXX`, the error message is telling you exactly which key it needs. Import that specific key by its ID — do not guess which key file from the vendor's website contains it.

**Task ordering matters:** Any task with `update_cache: yes` in the `apt` module triggers a full apt update across all repositories — including Jenkins. If the Jenkins repository is already added (from a previous failed run) but the key is wrong, even installing unrelated packages like Java will fail. The key and repository setup must always come first in the playbook.

## Interview Talking Points

- "I use Ansible for server configuration because it's agentless — there's nothing to install or maintain on target servers, which reduces attack surface and operational overhead"
- "All Ansible playbooks are idempotent — running them twice produces the same result as running them once, which makes them safe to re-run after partial failures"
- "I ran Ansible from WSL because it doesn't support Windows natively — the world-writable filesystem restriction required passing all config explicitly on the command line rather than relying on ansible.cfg auto-loading"
- "I use the `creates` argument on shell tasks to make them idempotent — the task is skipped if the target file already exists"
- "I always test connectivity with `ansible all -m ping` before running playbooks — this catches SSH or inventory issues before a long playbook run fails partway through"
- "I learned the hard way that `changed` in Ansible means the task ran — not that it succeeded. A shell task whose last command exits 0 will report changed even if every meaningful step before it failed. I now add `set -e` to all multi-step shell scripts"
- "When apt reports `NO_PUBKEY XXXX`, that error message tells you exactly which key you need. I spent four failed attempts importing the wrong key before I understood the correct fix: fetch that exact key ID from the keyserver rather than guessing which vendor file contains it"
- "Task ordering in Ansible matters — any `apt` task with `update_cache: yes` refreshes all repositories, including ones added by earlier tasks. If a repository is configured with a bad key, even installing unrelated packages will fail. Key and repository setup must always come first"
- "I use `failed_when: false` on tasks that may legitimately return a non-zero exit code — like reading the Jenkins initial admin password file, which only exists on first setup"
- "On a t2.micro with 1GB RAM, Jenkins holds ~600MB. Any system maintenance must be done with Jenkins stopped — otherwise apt cannot allocate the memory it needs to install packages"
