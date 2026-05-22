# CloudCommerce DevOps Platform

A production-grade DevOps platform built around Google's Online Boutique — a 12-microservice e-commerce application written in Go, Python, Java, C#, and Node.js. This project was built from scratch to demonstrate real-world DevOps engineering: architectural decisions, security design, infrastructure automation, CI/CD pipelines, Kubernetes orchestration, and full-stack observability.

> This is not a tutorial follow-along. Every decision in this project was made deliberately, with a specific reason, and is documented here alongside the evidence that it was implemented.

**Application source:** [Google Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo)

---

## Why This Project Exists

Most DevOps portfolios deploy a single containerised application to a managed Kubernetes service and call it done. This project takes a different approach: build the entire platform from scratch — networking, identity, compute, CI/CD, orchestration, and observability — making real engineering decisions along the way and documenting every one of them.

The goals are:
- Design and provision a complete AWS infrastructure using Infrastructure as Code
- Build a production-grade CI/CD pipeline that builds, scans, and deploys automatically
- Run a real 12-microservice application on Kubernetes under real traffic
- Demonstrate security practices that would be expected in a professional environment
- Keep costs under control through disciplined infrastructure management

---

## Architecture

```
Developer pushes code to GitHub
         │
         ▼ webhook
    ┌─────────────┐
    │   Jenkins   │  ← CI/CD on EC2 t3.medium (eu-central-1)
    │  Pipeline   │    Build → Scan → Push → Trigger
    └──────┬──────┘
           │ triggers ArgoCD sync
           ▼
    ┌─────────────┐         ┌──────────────────────────┐
    │   ArgoCD    │────────►│     k3s Kubernetes       │
    │  (GitOps)   │  sync   │     EC2 t3.medium        │
    └─────────────┘         │                          │
                            │  12 Microservices        │
                            │  Prometheus + Grafana    │
                            │  Loki + Promtail         │
                            │  k9s (terminal dashboard)│
                            └────────────┬─────────────┘
                                         │
                        ┌────────────────┼──────────────┐
                        ▼                ▼               ▼
                  ┌──────────┐   ┌────────────┐  ┌────────────┐
                  │ AWS ECR  │   │   AWS S3   │  │  Route53   │
                  │ 12 Repos │   │ TF State   │  │    DNS     │
                  └──────────┘   └────────────┘  └────────────┘

     All infrastructure provisioned with Terraform
     All server configuration managed with Ansible
```

---

## Key Architectural Decisions

### k3s over EKS
EKS (AWS managed Kubernetes) costs $0.10/hour for the control plane alone — $72/month before a single worker node is added. For a portfolio project, this is significant cost with no engineering benefit. k3s is a CNCF-certified, production-grade Kubernetes distribution that runs the complete Kubernetes API on a single EC2 instance. We get full Kubernetes features — HPA, RBAC, Ingress, persistent volumes, ArgoCD — at a fraction of the cost. In a real organisation, EKS would be the correct choice for its managed control plane, deep AWS integration, and enterprise support. For this project, k3s is the right engineering decision.

### Stop/Start over Destroy/Apply
Rather than destroying and recreating infrastructure every session, both EC2 servers are stopped between working sessions and started again when needed. AWS charges nothing for stopped EC2 instances (only a small EBS storage charge). Elastic IPs ensure the server addresses never change, so SSH config, Ansible inventory, and kubectl config all remain valid. This pattern preserves installed software between sessions while keeping running costs near zero.

### Modules and Environments separation
Terraform code is split into reusable modules (VPC, EC2, ECR, IAM) and environment-specific deployments (dev, prod). Modules define the *how* — how to build a VPC, how to create IAM roles. Environments define the *what and where* — which instance sizes, which region, which settings. This means fixing a bug in a module immediately benefits both environments, and adding a prod environment requires no module changes — only new variable values.

---

## Tech Stack

| Category | Tool | Rationale |
|----------|------|-----------|
| Cloud | AWS (eu-central-1) | Industry standard; Frankfurt region for GDPR compliance |
| IaC | Terraform 1.10+ | Declarative, version-controlled infrastructure; native S3 locking |
| Config Mgmt | Ansible | Agentless; SSH-based; idempotent server configuration |
| Containers | Docker | Standard container runtime; multi-stage builds for lean images |
| Orchestration | k3s | Full Kubernetes API at a fraction of EKS cost |
| CI/CD | Jenkins | Industry-standard; highly configurable pipeline-as-code |
| GitOps | ArgoCD | Git as the single source of truth for Kubernetes state |
| Registry | AWS ECR | Private; IAM-integrated; automatic image scanning |
| Metrics | Prometheus + Grafana | De facto Kubernetes observability stack |
| Logging | Loki + Promtail | Lightweight log aggregation; Grafana-native |
| Monitoring | k9s | Real-time terminal Kubernetes dashboard |
| Security | Trivy + Vault | Image vulnerability scanning + secrets management |
| Load Testing | k6 | Developer-friendly; JavaScript-based load scripts |
| Package Mgmt | Helm | Kubernetes application templating and versioning |

---

## Phase 1 — Foundation: Infrastructure as Code

Phase 1 covers everything required to have two production-ready servers running in AWS, fully provisioned and configured by code, with no manual console clicking.

### Step 1 — Repository and Git Discipline

The project starts with a Git repository before any infrastructure exists. This is intentional — infrastructure code needs the same version control discipline as application code.

The `.gitignore` is the first file created. It blocks:
- `.terraform/` — Terraform's local provider cache (can be hundreds of MB, regenerated by `init`)
- `*.tfstate` — Terraform state files (contain resource IDs and sometimes sensitive values)
- `*.pem`, `*.key`, `*.csv` — SSH private keys and credential export files
- `*accessKeys*`, `*credentials*` — AWS credential files
- `terraform/keys/cloudcommerce-dev-key` — the SSH private key path specifically

The rule applied throughout: if it contains a secret, a key, or can be regenerated — it belongs in `.gitignore` before a single `git add` is run. Credentials committed to a public GitHub repository are found by automated bots within minutes. The bots spin up thousands of EC2 instances for cryptocurrency mining. AWS bills accumulate until you notice — often thousands of dollars.

The repository was created on GitHub and the first commit was the `.gitignore`. Every meaningful change since has followed this discipline:

```
git add <specific files>    → stage intentionally, never git add -A blindly
git status                  → verify exactly what is staged
git commit -m "type: desc"  → conventional commit format
git push                    → make the work permanent
```

![GitHub repository](docs/screenshots/01-github-repo-readme.png)
*The project repository on GitHub — README, structured Terraform code, and documented learnings all visible from the first visit*

---

### Step 2 — AWS Account Isolation

A dedicated IAM user (`cloudcommerce-devops`) was created for this project rather than using an existing account or root credentials.

**Why not root:** The root user is the master key to an AWS account. Root credentials cannot be scoped, cannot be rotated the same way as IAM keys, and if compromised give an attacker full control — including locking you out. Root is used only for initial account setup and never for daily work.

**Why a dedicated IAM user:** This project runs in an AWS account that also has other projects. Using a shared user would mix credentials and risk accidentally provisioning resources in the wrong project context. A dedicated `cloudcommerce-devops` user means its credentials are scoped to this project and can be rotated or deleted without affecting anything else.

**Why a user group:** The `cloudcommerce-devops` user is placed in a `cloudcommerce-admins` group. Permissions are attached to the group, not the user. When a team grows, adding a new engineer means adding them to the group — not manually re-configuring every permission for every person.

![IAM User Group](docs/screenshots/02-iam-user-group.png)
*cloudcommerce-admins group — permissions managed at the group level, not per user*

![IAM User](docs/screenshots/03-iam-user.png)
*cloudcommerce-devops user — isolated credentials for this project only*

The AWS CLI is configured with a named profile so every command is explicitly scoped to this project:

```bash
aws configure --profile cloudcommerce
aws sts get-caller-identity --profile cloudcommerce  # always verify before running anything
```

Named profiles prevent the most common and expensive infrastructure mistake: running `terraform apply` authenticated as the wrong account.

---

### Step 3 — Remote State

Terraform tracks everything it has created in a state file (`terraform.tfstate`). Without state, Terraform cannot tell what already exists and would attempt to recreate everything from scratch on every `apply`.

Local state works for a single engineer on a single machine. It breaks the moment:
- The laptop is lost or the disk fails
- A second engineer needs to run Terraform
- Two people run `apply` simultaneously and corrupt the state

State is stored in S3 (`cloudcommerce-tfstate-<account-id>`) with two critical settings enabled:

**Versioning** — S3 keeps every previous version of the state file. If a bad `apply` corrupts state, the previous version can be restored. Without versioning, a corrupted state file means manually reconciling what Terraform thinks exists against what actually exists in AWS — an extremely painful process.

**Native S3 locking (Terraform 1.10+)** — Prevents two simultaneous `terraform apply` runs from writing to the state file at the same time. A corrupted state file in a team environment can break the entire project.

**Encryption** — State files can contain resource IDs, ARNs, and occasionally sensitive values. SSE-S3 encryption ensures the file is encrypted at rest.

![S3 State Bucket — Versioning](docs/screenshots/04-s3-tfstate-bucket.png)
*Versioning enabled — every state change is preserved and recoverable*

![S3 State Bucket — Encryption](docs/screenshots/04-s3-tfstate-bucket1.png)
*SSE-S3 encryption — state file encrypted at rest*

---

### Step 4 — Terraform Architecture

The Terraform code is split into two layers:

```
terraform/
├── modules/          ← reusable blueprints (the HOW)
│   ├── vpc/          how to build a VPC
│   ├── ec2/          how to build EC2 instances
│   ├── ecr/          how to build container registries
│   └── iam/          how to build roles and policies
└── environments/
    └── dev/          ← deployments (the WHAT and WHERE)
        ├── providers.tf    which cloud, which region, which credentials
        ├── backend.tf      where to store state
        ├── variables.tf    what inputs this environment accepts
        ├── terraform.tfvars the actual values for those inputs
        ├── main.tf         calls all modules with those values
        └── outputs.tf      what to print after apply
```

Modules have no knowledge of which environment they run in. The VPC module knows how to build a VPC — the CIDR ranges, subnet sizes, and region are passed in as variables. The dev environment calls the VPC module with dev values; a prod environment would call the same module with different values. Fix a bug in a module once and every environment that uses it benefits.

The `providers.tf` separates AWS authentication from infrastructure logic:

```hcl
provider "aws" {
  region  = var.aws_region
  profile = "cloudcommerce"
  default_tags {
    tags = { Project = var.project, Environment = var.environment, ManagedBy = "terraform" }
  }
}
```

`default_tags` automatically applies consistent tags to every resource created. Every EC2 instance, security group, subnet, and IAM role in this project is tagged with `Project = cloudcommerce`, `Environment = dev`, and `ManagedBy = terraform`. In a large AWS account with hundreds of resources, this tagging discipline is what makes cost tracking and resource identification manageable.

![Project Structure](docs/screenshots/05-project-structure.png)
*Repository structure in VS Code — the modules/environments separation is visible in the Terraform directory*

---

### Step 5 — Network Design

The VPC (`cloudcommerce-dev-vpc`, CIDR `10.0.0.0/16`) is the private network boundary for the entire project. All resources live inside it.

```
VPC: 10.0.0.0/16  (65,536 addresses — large enough for future growth)
├── Public Subnet: 10.0.1.0/24   ← Jenkins + k3s (need internet access)
└── Private Subnet: 10.0.2.0/24  ← future databases (no internet access)
```

**Why a public/private split:** The principle of least exposure — only resources that genuinely need internet access are placed in the public subnet. Jenkins needs to be reachable for GitHub webhooks. k3s needs to serve application traffic. Databases do not. A database in the private subnet has no route to the internet gateway, so even if the application is compromised, an attacker cannot directly reach the database from outside — they would first need to compromise a server in the public subnet.

**Route tables vs security groups** — these operate at different layers and both must permit traffic for it to flow:
- Route tables operate at the **subnet level** — they decide *where* traffic is directed (e.g., all outbound traffic goes to the internet gateway)
- Security groups operate at the **instance level** — they decide *who* is allowed through (e.g., only port 80 is accepted)

A packet arriving at the VPC passes through the route table first (does a path to this destination exist?) and then through the security group (is this traffic type permitted?). Both must say yes.

Jenkins security group — ports 22 (SSH admin access) and 8080 (Jenkins web UI)
k3s security group — ports 22, 80, 443 (application traffic), 6443 (Kubernetes API for kubectl), 30080 (ArgoCD dashboard)

![VPC](docs/screenshots/08-vpc.png)
*cloudcommerce-dev-vpc — isolated network boundary for the project*

![VPC Subnets](docs/screenshots/09-vpc-subnets.png)
*Public and private subnets — only the public subnet has a route to the internet gateway*

![Private Subnet](docs/screenshots/10-vpc-private-subnet.png)
*Private subnet detail — no internet gateway route, databases will live here*

---

### Step 6 — Identity Design

By default, EC2 instances have zero AWS permissions. A Jenkins server that needs to push Docker images to ECR cannot do so without explicit permission. The wrong solution is putting AWS access keys on the server — if the server is ever compromised, those long-lived credentials are stolen. The correct solution is IAM roles.

IAM roles generate **temporary credentials** automatically, rotating every few hours. Nothing sensitive is stored on disk. If the server is compromised, the credentials expire on their own schedule and cannot be exfiltrated permanently.

Two roles were created with deliberately different permissions:

```
Jenkins Role → ECR push + pull
  Can: build images, push to ECR, pull from ECR, describe and list repositories

k3s Role → ECR pull only
  Can: pull images from ECR, describe and list repositories
  Cannot: push images, modify repositories
```

This separation matters. k3s only runs images — it never builds them. Giving k3s push permissions would mean a compromised k3s node could push malicious images to ECR, which Jenkins would then pull and deploy. By restricting k3s to pull-only, an attacker who compromises the k3s node cannot inject code into the build pipeline. The attack surface is limited by design.

![IAM Roles](docs/screenshots/12-iam-roles.png)
*Jenkins role (push+pull) and k3s role (pull-only) — least privilege enforced at the IAM level*

---

### Step 7 — Container Registry

ECR (Elastic Container Registry) provides 12 private repositories — one per microservice. The naming convention is `cloudcommerce/<service-name>` (e.g., `cloudcommerce/frontend`, `cloudcommerce/cartservice`).

Two settings are enabled on every repository:

**Scan on push** — every image is automatically scanned for known CVEs (Common Vulnerabilities and Exposures) when pushed. The scan results appear in the ECR console. This provides a baseline security gate without adding complexity to the pipeline.

**Lifecycle policy** — keeps the last 5 images per repository and automatically expires older ones. Without lifecycle policies, a CI/CD pipeline pushing multiple images per day will accumulate hundreds of gigabytes of stale images in ECR within weeks. Storage is cheap, but unchecked accumulation is wasteful and signals a lack of operational discipline.

The 12 repositories are created with a single Terraform `for_each` block rather than 12 identical resource blocks:

```hcl
resource "aws_ecr_repository" "services" {
  for_each = toset(var.services)
  name     = "${var.project}/${each.key}"
}
```

Adding a 13th service requires adding one name to a list. No module code changes.

![ECR Repositories](docs/screenshots/11-ecr-repos.png)
*12 container registries — one per microservice, scan on push enabled on all*

---

### Step 8 — Compute

Two EC2 instances are provisioned:

| Instance | Type | Disk | Purpose |
|----------|------|------|---------|
| Jenkins | t2.micro | 20GB gp3 | CI/CD pipeline — build, scan, push |
| k3s | t3.medium | 30GB gp3 | Kubernetes node — runs all 12 services |

**Why t3.medium for k3s:** Running 12 microservices simultaneously requires memory. A t2.micro (1GB RAM) would cause out-of-memory kills under normal load. A t3.medium (4GB RAM) provides enough headroom for the application, the Kubernetes system pods, Prometheus, Grafana, and Loki to coexist.

**SSH key pairs:** EC2 instances use public/private key authentication instead of passwords. A 4096-bit RSA key pair was generated locally. The public key was uploaded to AWS and attached to both instances at creation. The private key stays only on the engineer's machine and is gitignored. Knowing a server's IP address without the corresponding private key results in immediate `Permission denied` — there is no password to brute-force.

**user_data bootstrap:** Both instances run a shell script automatically on first boot via the `user_data` field in the Terraform resource. This script installs Docker CE, enables the Docker daemon, and starts it. The server is fully ready — Docker running, daemon enabled for automatic restart — before any engineer touches it. This is what "infrastructure as code" means in practice: the server configures itself.

**Elastic IPs:** Standard EC2 instances are assigned a dynamic public IP that changes every time the instance stops and starts. This would break SSH commands, Ansible inventory, and kubectl configuration every session. Elastic IPs are static public addresses that remain attached through stop/start cycles. They are free while the instance is running and cost ~$0.005/hour while stopped.

![EC2 Instances](docs/screenshots/06-ec2-instances.png)
*Both instances running in eu-central-1a after terraform apply*

![Elastic IPs](docs/screenshots/07-elastic-ips.png)
*Static Elastic IPs attached to both servers — addresses will not change between sessions*

---

### Step 9 — Provisioning

With all four modules complete (VPC, IAM, ECR, EC2), the infrastructure is provisioned with a single command:

```bash
terraform plan   # review exactly what will be created — always read this
terraform apply  # provision everything
```

The initial apply created **43 resources** in under 60 seconds:
- 1 VPC, 2 subnets, 1 internet gateway, 1 route table, 1 route table association
- 2 IAM roles, 2 IAM policies, 2 policy attachments, 2 instance profiles
- 12 ECR repositories, 12 ECR lifecycle policies
- 1 SSH key pair, 2 EC2 instances, 2 security groups

A second apply added 2 Elastic IPs — demonstrating Terraform's incremental apply behaviour. Existing resources were read from state and left completely untouched. Only the 2 new resources were created.

![Terraform Apply — 43 Resources](docs/screenshots/13-terraform-apply-43.png)
*Initial apply output — 43 resources created, 0 changed, 0 destroyed*

![Terraform Apply — Elastic IPs](docs/screenshots/14-terraform-apply-eip.png)
*Incremental apply — 2 resources added, 43 existing resources untouched*

---

### Step 10 — Verification

After provisioning, both servers were SSH'd into to confirm the user_data bootstrap ran successfully:

```bash
ssh -i terraform/keys/cloudcommerce-dev-key ubuntu@3.127.90.169
docker --version
sudo systemctl status docker --no-pager
```

Results on both servers:
- Ubuntu 22.04.5 LTS — correct AMI
- Docker 29.5.1 — installed by user_data
- `Active: active (running)` — daemon started and enabled

This verification step matters. `user_data` runs silently at boot with no visible output. Checking `docker --version` is the confirmation that the script ran to completion. Skipping this check and proceeding to Ansible without verifying Docker would mean debugging a failure several steps later with no indication of where it originated.

![SSH Verification](docs/screenshots/15-ssh-verify.png)
*SSH into Jenkins server — Ubuntu 22.04 booted, private IP 10.0.1.253 confirms VPC placement*

![Docker Version](docs/screenshots/16-docker-version.png)
*Docker 29.5.1 installed automatically by user_data bootstrap script*

![Docker Status](docs/screenshots/17-docker-status.png)
*Docker daemon active and running — enabled for automatic restart on reboot*

---

### Step 11 — Cost Management: The Stop/Start Pattern

Infrastructure is not left running between working sessions. Both EC2 instances are stopped via the AWS Console at the end of every session and started again at the beginning of the next.

**Starting a session:**
1. AWS Console → EC2 → Instances → select both → Instance State → Start
2. Wait ~30 seconds for Running state
3. Verify SSH: `ssh -i terraform/keys/cloudcommerce-dev-key ubuntu@3.127.90.169`
4. Elastic IPs ensure the same addresses — no configuration changes needed

**Ending a session:**
1. AWS Console → EC2 → Instances → select both → Instance State → Stop
2. Compute billing stops immediately
3. EBS disks and Elastic IPs persist — all installed software is preserved

This was tested: both instances were stopped overnight and restarted the following day. SSH connected immediately to the same IPs. All data and configuration on the EBS volumes was intact.

| State | Cost |
|-------|------|
| Both instances running | ~$0.065/hour |
| Both instances stopped | ~$0.27/day |
| Full project to completion | ~$15–25 total |

![Instances Restarted](docs/screenshots/20-ec2-instances-restarted.png)
*Both instances Running after overnight stop — Elastic IPs confirmed unchanged*

![SSH Jenkins After Restart](docs/screenshots/18-ssh-jenkins-verify.png)
*Jenkins SSH after restart — same IP (3.127.90.169), same private address (10.0.1.253)*

![SSH k3s After Restart](docs/screenshots/19-ssh-k3s-verify.png)
*k3s SSH after restart — same IP (63.184.235.88), stop/start pattern confirmed working*

---

## Phase 2 — CI/CD Pipeline *(in progress)*

### Ansible Setup — Configuring Servers Without Touching Them

Ansible is the configuration management layer. Where Terraform provisions infrastructure (what exists in AWS), Ansible configures what runs on those servers — installing packages, writing config files, starting services, managing users. It is agentless: there is nothing to install on the target servers. Ansible SSHes in from the control node, runs tasks, and disconnects. Every task is idempotent — running the same playbook twice produces the same result without duplicating work.

The control node for this project is WSL (Windows Subsystem for Linux) on the local machine, running Ubuntu 22.04. Ansible does not run natively on Windows, so WSL provides the Linux environment required.

#### Step 1 — Install Ansible on WSL

Ansible was installed via pip rather than Ubuntu's packaged version. The Ubuntu package is typically several versions behind; pip gives the current release.

![WSL Ubuntu Start](docs/screenshots/20a-wsl-ubuntu-start.png)
*WSL Ubuntu 22.04 — the Ansible control node for this project*

![Ansible Install](docs/screenshots/20b-ansible-install.png)
*Ansible installed via pip — current release, not Ubuntu's older packaged version*

![Ansible Version](docs/screenshots/20c-ansible-version.png)
*ansible --version confirms installation and the Python interpreter being used*

#### Step 2 — SSH Key Setup

The SSH private key lives in `terraform/keys/` on the Windows filesystem. For Ansible to use it from WSL, it must be copied into the WSL home directory with restrictive permissions. SSH (and by extension Ansible) refuses to use private keys that are readable by other users — this is a hard security requirement, not a warning.

```bash
cp /mnt/c/Users/OnlyM/Devops\ Project/cloudcommerce-devops/terraform/keys/cloudcommerce-dev-key ~/.ssh/
chmod 600 ~/.ssh/cloudcommerce-dev-key
```

![SSH Key Setup](docs/screenshots/21-wsl-ansible-ssh-key-setup.png)
*Private key copied to WSL home directory with chmod 600 — SSH security requirement enforced*

---

#### Challenge: Ansible Refused to Load Config from the Windows Filesystem

The first ping attempt produced no hosts at all — not a connection failure, but Ansible silently ignoring its own configuration:

```
[WARNING]: Ansible is being run in a world writable directory, ignoring it as an ansible.cfg source.
[WARNING]: provided hosts list is empty, only localhost is available.
```

![Ansible World-Writable Warning](docs/screenshots/22-ansible-wsl-worldwritable-warning.png)
*Ansible ignores ansible.cfg from /mnt/c/ — world-writable filesystem is treated as untrusted*

**Root cause:** The Windows filesystem mounted in WSL at `/mnt/c/` has world-writable permissions by default. Ansible has a deliberate security rule that refuses to auto-load `ansible.cfg` from world-writable directories — on a shared system, a malicious `ansible.cfg` in a world-writable directory could inject configuration without the user knowing. Without the config file, Ansible found no inventory and no hosts.

**Solution:** Pass inventory and credentials explicitly on every command instead of relying on auto-loading:

```bash
ansible all -i inventory/hosts -m ping --private-key ~/.ssh/cloudcommerce-dev-key -u ubuntu
```

**What this teaches:** Understanding *why* a tool rejects configuration — not just that it does — is the difference between a real fix and a blind workaround. The restriction exists for a genuine security reason. The correct response is to work with it, not disable it.

---

Both servers responded immediately once the explicit flags were passed:

![Ansible Ping Success](docs/screenshots/23-ansible-ping-success.png)
*Both servers respond with pong — Ansible SSH connectivity to Jenkins (3.127.90.169) and k3s (63.184.235.88) confirmed*

---

### Writing the Jenkins Playbook

With connectivity proven, the first playbook was written to install Jenkins. A single YAML file automates the complete setup: Java 17 (Jenkins runtime dependency), GPG key import, apt repository configuration, Jenkins installation and service management, Docker group membership for the jenkins user, and initial admin password retrieval.

![Jenkins Playbook](docs/screenshots/24-jenkins-playbook.png)
*setup-jenkins.yml in VS Code — initial version using Java 17, later upgraded to Java 21*

---

### Challenge: Jenkins GPG Key — Two Separate Problems

Installing Jenkins exposed two distinct GPG key problems encountered in sequence. Each required a different diagnosis technique.

#### Problem 1 — Key Format: `.asc` vs `.gpg`

The initial playbook used `get_url` to download Jenkins' GPG key as an ASCII-armored `.asc` file. Apt's `signed-by` mechanism requires keys in binary (dearmored) format. The mismatch caused every `apt-get update` to reject the repository as unsigned:

```
NO_PUBKEY 7198F4B714ABFC68
E: The repository 'https://pkg.jenkins.io/debian-stable binary/ Release' is not signed.
```

![Ansible Jenkins Run Failed](docs/screenshots/25-ansible-jenkins-run-failed.png)
*First playbook run — FAILED at apt update, repository signature verification rejected*

![Ansible Jenkins Run Failed 2](docs/screenshots/25b-ansible-jenkins-run-failed2.png)
*Second run — same error after first attempted fix*

**Fix:** Pipe the downloaded key through `gpg --dearmor` to convert it from ASCII to binary format. The `apt_repository` Ansible module was also replaced with a `shell` task — the module auto-triggers a cache update internally before the key is fully in place, creating a race condition.

```bash
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
```

![Ansible Jenkins Run Failed 3](docs/screenshots/25c-ansible-jenkins-run-failed3.png)
*Third run after dearmor fix — same error. The problem was not the format.*

---

#### Problem 2 — Expired Key at the Official URL

The dearmor fix resolved the format issue but the same signature error persisted. More Ansible runs with further adjustments all produced the same result:

![Ansible Jenkins Run Failed 4](docs/screenshots/25d-ansible-jenkins-run-failed4.png)
*Fourth run — dearmor applied, same NO_PUBKEY error. The problem is not the format.*

![Ansible Jenkins Run Failed 5](docs/screenshots/25e-ansible-jenkins-run-failed5.png)
*Fifth run — all automated attempts exhausted. Root cause still unknown.*

After five failures with the same error, automated retries were stopped. The next step was SSH directly into the Jenkins server to inspect what was actually on disk:

![Jenkins Repo First Attempt](docs/screenshots/26a-jenkins-repo-first-attempt.png)
*Manual commands on the server — checking the key file and testing apt-get update directly*

```bash
gpg --show-keys /usr/share/keyrings/jenkins-keyring.gpg
```

Output:

```
pub   rsa4096 2023-03-27 [SC] [expired: 2026-03-26]
      63667EE74BBA1F0A08A698725BA31D57EF5975CA
```

![Jenkins Wrong Key](docs/screenshots/26b-jenkins-wrong-key.png)
*gpg --show-keys reveals the key downloaded from jenkins.io-2023.key — fingerprint 5BA31D57EF5975CA, expired March 2026*

The key at `jenkins.io-2023.key` **expired in March 2026**. Its fingerprint (`5BA31D57EF5975CA`) does not match the key Jenkins is actually using to sign the repository (`7198F4B714ABFC68`). Jenkins rotated their signing key but the old URL continues to serve the expired key — a silent trap for anyone following documentation written before the rotation.

---

#### Resolution — Fetch the Current Key by ID from a Keyserver

Rather than downloading from a URL that serves whatever key the Jenkins team last published there, fetch the specific key by its ID from a dedicated key distribution server:

```bash
sudo gpg --no-default-keyring \
    --keyring /usr/share/keyrings/jenkins-keyring.gpg \
    --keyserver keyserver.ubuntu.com \
    --recv-keys 7198F4B714ABFC68
```

A keyserver lookup by ID always returns the current valid key for that ID. The playbook was rewritten with this approach, and `apt-get update` was run manually on the server first to confirm the fix before finalising the playbook.

![Jenkins Repo Verified Success](docs/screenshots/27-jenkins-repo-verified-success.png)
*apt-get update succeeds — Jenkins repository trusted, packages now available for installation*

**What this teaches:** Package signing keys expire and rotate. Hardcoding a key URL in automation is fragile — the URL may serve a stale or expired key indefinitely after rotation. Fetching by key ID from a keyserver always retrieves the current valid key. Manual server debugging (SSH in, run the failing command by hand, inspect the artefacts) is often the fastest path to the actual root cause when automated retries produce the same error.

---

### Challenge: Jenkins Installed but Service Failed to Start — Java Version

With the GPG key issue resolved, the playbook ran successfully — Jenkins installed — but failed at the final step: starting the service.

```
TASK [Start and enable Jenkins]
fatal: [3.127.90.169]: FAILED! => {"msg": "Unable to start service jenkins: Job for
jenkins.service failed because the control process exited with error code."}
```

![Jenkins Service Start Failed](docs/screenshots/27a-jenkins-service-start-failed.png)
*Ansible output — ok=6, changed=2, failed=1. Jenkins installed successfully but service refused to start*

The systemctl and journalctl logs showed only that the process exited — not why. The fastest way to get the actual error was to run Jenkins directly:

```bash
sudo /usr/bin/jenkins
```

Output:

```
Running with Java 17 from /usr/lib/jvm/java-17-openjdk-amd64, which is older than
the minimum required version (Java 21).
Supported Java versions are: [21, 25]
```

![Jenkins Java 17 Not Supported](docs/screenshots/27b-jenkins-java17-not-supported.png)
*Jenkins executed directly — Java 17 rejected, minimum requirement is now Java 21*

**Root cause:** Jenkins dropped Java 17 support in recent releases. The playbook was written against older documentation that listed Java 17 as the supported version. The current Jenkins LTS requires Java 21 minimum.

**Fix:** Update the playbook to remove Java 17 and install Java 21. Java 17 takes ~200MB — removing it also keeps disk usage clean on the 20GB t2.micro volume.

```yaml
- name: Remove Java 17 if present
  apt:
    name: openjdk-17-jdk
    state: absent

- name: Install Java 21 and dependencies
  apt:
    name:
      - openjdk-21-jdk
      - curl
      - gnupg
    state: present
```

![Playbook Java 21 Fix](docs/screenshots/27c-playbook-java21-fix.png)
*Updated playbook — Java 17 removal task added before Java 21 install*

Re-running the playbook: Ansible removed Java 17, installed Java 21, and this time Jenkins started cleanly.

![Ansible Java Upgrade Running](docs/screenshots/27d-ansible-java-upgrade-running.png)
*Ansible run in progress — Java 17 removed (changed), Java 21 installed (changed)*

![Ansible Jenkins Install Success](docs/screenshots/27e-ansible-jenkins-install-success.png)
*Full successful run — 12 tasks ok, 5 changed, 0 failed. Jenkins started and initial password retrieved*

**What this teaches:** Software version requirements change. Locking to a specific version in automation and re-verifying after major releases is not optional — Jenkins silently accepted the wrong Java version at install time and only rejected it at runtime. Running the binary directly (`/usr/bin/jenkins`) is a fast diagnostic technique that bypasses systemd's wrapper and surfaces the real error immediately.

---

### Jenkins Initial Configuration

With Jenkins running, the web UI was opened at `http://3.127.90.169:8080`. The initial unlock screen requires the admin password that Ansible printed at the end of the playbook run.

![Jenkins Unlock Page](docs/screenshots/27f-jenkins-unlock-page.png)
*Jenkins unlock screen — initial admin password retrieved from Ansible output*

**Suggested plugins** were selected — this installs the standard set Jenkins recommends: Git, Pipeline, Credentials, GitHub integration, and build tools. Selecting plugins manually at this stage adds risk of missing dependencies with no benefit.

![Jenkins Plugins Installing](docs/screenshots/28-jenkins-unlock-plugins.png)
*Suggested plugins installing — Git, Pipeline, Credentials, GitHub, and supporting tools*

An admin account was created and Jenkins is now fully operational.

![Jenkins Dashboard](docs/screenshots/29-jenkins-dashboard.png)
*Jenkins dashboard — CI/CD server live and accessible at http://3.127.90.169:8080*

---

### Progress
- [x] Ansible connectivity verified — both servers reachable (ping: pong)
- [x] Jenkins GPG key issue diagnosed and resolved — keyserver approach adopted
- [x] Jenkins installed via Ansible — Java 17→21 upgrade required and documented
- [x] Jenkins configured — admin account created, suggested plugins installed
- [ ] Add AWS credentials and GitHub token to Jenkins credential store
- [ ] Write Jenkinsfile — build, scan with Trivy, push to ECR
- [ ] Configure GitHub webhook → Jenkins trigger
- [ ] Set up ArgoCD for GitOps deployment

---

## Phase 3 — Kubernetes

### Why k3s

k3s is a CNCF-certified Kubernetes distribution built for resource-constrained environments. On an EC2 t3.medium with 20GB storage, full upstream Kubernetes would consume most available memory before any workloads run. k3s ships as a single binary (~100MB), uses less than 512MB RAM at idle, and includes everything needed for a production-grade cluster: containerd, CoreDNS, Traefik ingress, and persistent volume support. It is fully Kubernetes-compatible — every `kubectl` command, every Helm chart, every manifest written for upstream Kubernetes works identically on k3s.

The t3.medium running k3s has 2 vCPUs and 4GB RAM — sufficient for the 12-microservice Online Boutique application plus Prometheus, Grafana, and ArgoCD.

---

### Pre-flight Checks — Verifying the Server Before Installation

Before running the k3s playbook, Ansible connectivity to the k3s server was verified using the same `ansible ping` command used in Phase 2. The k3s server was also inspected to confirm Docker was running, disk had sufficient space, and memory was adequate.

![k3s Ansible Ping Success](docs/screenshots/30-k3s-ansible-ping-success.png)
*Ansible ping to k3s server (63.184.235.88) succeeds — SSH connectivity confirmed before playbook run*

![k3s Server Resources Verified](docs/screenshots/31-k3s-docker-verified.png)
*Docker running, disk and RAM verified on the k3s EC2 instance — server ready for k3s installation*

---

### Installing k3s via Ansible

k3s is not available via apt. It is installed by piping a shell script from the official k3s distribution server directly into the shell — a single curl command that downloads and installs the binary, configures systemd, and starts the service in one step.

The Ansible playbook automates this:

```yaml
- name: Download and install k3s
  shell: curl -sfL https://get.k3s.io | sh -

- name: Wait for k3s API server to be available
  wait_for:
    port: 6443
    delay: 10
    timeout: 120

- name: Wait for node to reach Ready state
  shell: k3s kubectl get node | grep -v NotReady | grep Ready
  register: node_ready
  until: node_ready.rc == 0
  retries: 12
  delay: 10
  changed_when: false
```

The `wait_for` task pauses until port 6443 (the Kubernetes API server) is accepting connections. The follow-up task polls until the node reaches Ready state — k3s starts the API server before the node is fully initialised, so both checks are necessary.

![k3s First Install Success](docs/screenshots/32-k3s-install-success.png)
*k3s playbook first run — all tasks ok, cluster installed and node reached Ready state*

---

### Setting Up kubectl — Local Cluster Access

kubectl is the Kubernetes CLI — it runs locally, connects to the cluster API over HTTPS on port 6443, and sends commands to the cluster. To connect kubectl to the k3s cluster, the cluster's credentials file (kubeconfig) must be copied from the server to the local machine.

#### kubectl Installation — Four Failures Before Success

Getting kubectl onto Windows turned into a multi-step debugging exercise that required working around several issues in sequence.

**Attempt 1 — winget**

The first approach was the Windows package manager:

```powershell
winget install -e --id Kubernetes.kubectl
```

Winget reported success ("Erfolgreich installiert"). But `kubectl` could not be found anywhere on the system — `Get-Command kubectl` returned nothing, `where.exe kubectl` returned nothing. The installation completed without error but placed the binary somewhere outside the PATH with no indication of where.

![winget kubectl install](docs/screenshots/32a-winget-kubectl-install.png)
*winget reports success — but kubectl is not findable on the PATH after installation*

![kubectl not found](docs/screenshots/32b-kubectl-not-found.png)
*Get-Command kubectl and where.exe kubectl both return nothing — winget installed somewhere inaccessible*

**Attempt 2 — PowerShell Invoke-WebRequest to System32**

```powershell
Invoke-WebRequest -Uri "https://dl.k8s.io/release/v1.36.1/bin/windows/amd64/kubectl.exe" `
  -OutFile "C:\Windows\System32\kubectl.exe"
```

Access denied — writing to System32 requires elevated permissions that were not available in the current terminal session.

![kubectl reinstall attempt](docs/screenshots/32c-kubectl-reinstall-attempt.png)
*PowerShell Invoke-WebRequest to System32 — access denied, insufficient permissions*

**Attempt 3 — PowerShell Invoke-WebRequest to Project Directory**

```powershell
Invoke-WebRequest -Uri "https://dl.k8s.io/release/v1.36.1/bin/windows/amd64/kubectl.exe" `
  -OutFile "C:\Users\OnlyM\Devops Project\kubectl.exe"
```

The download started but the connection broke mid-transfer. Network interruption, no partial file recovered.

![kubectl download failed](docs/screenshots/32d-kubectl-download-failed.png)
*PowerShell download failed with connection error — no binary recovered*

**Resolution — WSL curl**

PowerShell's Invoke-WebRequest has known TLS and connection handling issues. WSL curl is more reliable for large binary downloads. From inside WSL:

```bash
curl -LO "https://dl.k8s.io/release/v1.36.1/bin/windows/amd64/kubectl.exe"
```

This downloaded the binary successfully into the current WSL directory, which is accessible from Windows at `C:\Users\OnlyM\Devops Project\`.

![kubeconfig first copy and kubectl download](docs/screenshots/32e-kubeconfig-first-copy-and-kubectl-download.png)
*kubeconfig copied from the server and kubectl.exe downloaded via WSL curl — binary available in the project directory*

---

### Challenge: TLS Certificate Error — Public IP Not in the Certificate

With kubectl available, the kubeconfig was copied from the k3s server and updated to point at the public Elastic IP:

```yaml
server: https://63.184.235.88:6443
```

Running `kubectl get nodes` produced a TLS certificate error:

```
tls: failed to verify certificate: x509: certificate is valid for
10.0.1.135, 10.43.0.1, 127.0.0.1, ::1, not 63.184.235.88
```

![kubectl TLS cert error](docs/screenshots/32f-kubectl-tls-cert-error.png)
*kubectl get nodes fails — k3s self-signed certificate does not include the public Elastic IP*

**Root cause:** k3s generates a self-signed TLS certificate during installation and includes a list of IPs the certificate is valid for (Subject Alternative Names). By default, it only includes the node's private IP (`10.0.1.135`), the cluster service IP (`10.43.0.1`), and loopback addresses. The public Elastic IP (`63.184.235.88`) is not in the certificate — so TLS verification fails when connecting from outside the VPC.

This is a design constraint of how TLS works: a certificate must explicitly list every IP or hostname it is valid for. The certificate is generated at install time, so there is no way to add the public IP after the fact without reinstalling.

**Fix:** The k3s install command accepts an `INSTALL_K3S_EXEC` environment variable that passes flags to the k3s server. The `--tls-san` flag adds entries to the TLS certificate's Subject Alternative Names list:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san 63.184.235.88" sh -
```

The Ansible playbook was updated:

![Playbook TLS SAN Fix](docs/screenshots/32g-playbook-tls-san-fix.png)
*setup-k3s.yml updated — INSTALL_K3S_EXEC="--tls-san 63.184.235.88" added to include the Elastic IP in the TLS certificate*

The `args.creates` guard that prevented re-running the install task was removed — k3s was already installed, but its certificate needed to be regenerated with the correct SANs.

#### k3s Reinstall

The updated playbook was run, triggering a clean reinstall of k3s with the correct TLS configuration:

![k3s reinstall command](docs/screenshots/32h-k3s-reinstall-command.png)
*Ansible playbook command with updated inventory and credentials — targeting the k3s reinstall*

![k3s reinstall running](docs/screenshots/32i-k3s-reinstall-running.png)
*k3s reinstalling — tasks running, node returning to Ready state with new TLS certificate*

---

### k3s Reinstall Success — TLS SAN Fixed

The second playbook run completed successfully with the updated certificate:

![k3s Second Install Success](docs/screenshots/33-k3s-install-success.png)
*k3s reinstall — all tasks complete, node Ready, new certificate includes 63.184.235.88 in SANs*

The kubeconfig was re-copied from the server (the first copy contained the old certificate's cluster authority data):

![kubeconfig copy](docs/screenshots/33a-kubeconfig-copy.png)
*Copying fresh kubeconfig from the server after reinstall — the cluster CA data has changed*

![kubeconfig copy result](docs/screenshots/33b-kubeconfig-copy-result.png)
*kubeconfig content — server set to https://63.184.235.88:6443, certificate-authority-data updated*

With the fresh kubeconfig in place, `kubectl get nodes` succeeded:

![kubectl get nodes success](docs/screenshots/33c-kubectl-get-nodes-success.png)
*kubectl get nodes — node ip-10-0-1-135 status Ready, control-plane role confirmed. Remote kubectl access to the cluster is working.*

**What this teaches:** k3s (and Kubernetes in general) generates TLS certificates at cluster initialisation time. For remote access from outside the cluster's internal network, the public-facing IP must be declared via `--tls-san` *before* installation — not added after. Discovering this through the x509 error is common; the fix is a full reinstall with the correct flag, which Ansible makes trivial to reproduce.

---

### Installing k9s — Terminal UI for Cluster Management

kubectl is the authoritative tool for Kubernetes operations. k9s is a terminal UI built on top of kubectl that makes it faster to navigate pods, view logs, and inspect cluster state without remembering the full kubectl syntax for every operation.

k9s was installed in WSL using the official installer script:

```bash
curl -sS https://webinstall.dev/k9s | bash
```

![k9s web install](docs/screenshots/33d-k9s-webinstall.png)
*k9s v0.50.18 installed via webinstall in WSL — binary placed in ~/.local/bin*

k9s was launched directly to the pods view to avoid navigating from the default start screen:

```bash
k9s --command pods
```

![k9s terminal launch](docs/screenshots/33e-k9s-terminal-launch.png)
*k9s launching — kubeconfig detected, connecting to k3s cluster at 63.184.235.88:6443*

All 7 system pods were Running with healthy resource usage — 3% CPU, 28% memory on the t3.medium node:

![k9s dashboard](docs/screenshots/34-k9s-dashboard.png)
*k9s pods view — 7 system pods all Running: coredns, metrics-server, traefik, local-path-provisioner, svclb-traefik. Cluster health confirmed.*

For comparison, the same cluster state from kubectl:

```bash
kubectl get pods -A
```

![kubectl all pods](docs/screenshots/35-kubectl-all-pods.png)
*kubectl get pods -A — all namespaces, all pods Running. k9s and kubectl showing identical cluster state.*

---

### Making kubectl PATH Permanent on Windows

The temporary PATH addition (`$env:PATH += "..."`) does not persist across PowerShell sessions. The permanent fix uses the Windows environment registry directly via SetEnvironmentVariable:

```powershell
[System.Environment]::SetEnvironmentVariable(
    "PATH",
    $env:PATH + ";C:\Users\OnlyM\Devops Project",
    [System.EnvironmentVariableTarget]::User
)
```

New terminal sessions inherit the updated PATH automatically — no manual setup required.

![kubectl permanent path](docs/screenshots/36-kubectl-permanent-path.png)
*kubectl get nodes working in a new PowerShell session — PATH is permanent, no manual setup needed*

---

### Installing ArgoCD — GitOps Continuous Delivery

ArgoCD is the GitOps engine for this platform. Where Jenkins handles CI (build, scan, push), ArgoCD handles CD — it watches a Git repository and automatically syncs the cluster state to match what's defined there. Every deployment is a git commit. Every rollback is a git revert. The cluster always reflects what's in the repository.

#### Why Ansible Instead of Raw kubectl

The initial instinct was to run the ArgoCD install as a one-off `kubectl apply` command. The better approach — and the one taken here — was to write it as an Ansible playbook. The reasons:

- **Reproducibility:** the entire ArgoCD setup can be re-run from scratch on any cluster with one command
- **Documentation:** the playbook is the install record — no undocumented steps
- **Consistency:** all infrastructure changes in this project go through the same IaC discipline
- **Recovery:** if the cluster is rebuilt, `ansible-playbook setup-argocd.yml` restores the full GitOps layer automatically

A one-off kubectl command works once. An Ansible playbook works every time.

---

#### Challenge 1 — Annotation Too Large for Client-Side Apply

The first playbook run failed immediately:

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

![ArgoCD install failed](docs/screenshots/37-argocd-install-failed.png)
*First ArgoCD playbook run — FAILED. The applicationsets CRD annotation exceeds Kubernetes' 262144 byte limit*

**Root cause:** `kubectl apply` in its default (client-side) mode stores the entire last-applied manifest as an annotation on the resource. ArgoCD's ApplicationSet CRD is large enough that this annotation exceeds the 262144 byte hard limit Kubernetes enforces on annotations.

**Fix:** Switch to `--server-side` apply, which moves the field management tracking to the server and does not write the manifest into an annotation.

```yaml
shell: k3s kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

![ArgoCD server-side fix](docs/screenshots/37a-argocd-serverside-fix.png)
*Playbook updated — --server-side flag added to the kubectl apply command*

---

#### Challenge 2 — Field Manager Conflict Between Apply Modes

The second run failed with a different error:

```
Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1:
.spec.template.spec.containers[name="argocd-applicationset-controller"].env[name="NAMESPACE"].valueFrom.fieldRef
```

![ArgoCD second run failed](docs/screenshots/37b-argocd-second-run-failed.png)
*Second run — FAILED. Server-side apply conflicts with the client-side apply manager from the first run*

**Root cause:** The first run created resources using client-side apply, which registers `kubectl-client-side-apply` as the field manager. The second run is now using server-side apply, which uses a different field manager. Kubernetes rejected the handover because two managers were claiming ownership of the same fields.

**Fix:** Add `--force-conflicts` to instruct server-side apply to take ownership of all conflicting fields, overriding the previous client-side manager:

```yaml
shell: k3s kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

![ArgoCD force-conflicts fix](docs/screenshots/37c-argocd-force-conflicts-fix.png)
*Playbook updated again — --force-conflicts added to resolve field manager conflict*

---

#### ArgoCD Installation Success

Third run — all 7 tasks completed, 0 failed:

![ArgoCD install success](docs/screenshots/38-argocd-install-success.png)
*Full successful run — namespace created, ArgoCD installed, pods ready, service patched to NodePort 30080, initial password printed*

```
ArgoCD UI: https://63.184.235.88:30080 | username: admin | password: ****
```

---

#### ArgoCD UI — First Login

Opening `https://63.184.235.88:30080` shows the expected TLS warning — the same self-signed certificate situation as with the k3s API server. Click through to reach the login page.

![ArgoCD TLS warning](docs/screenshots/39-argocd-tls-warning.png)
*Browser TLS warning — self-signed cert, same as kubectl. Expected and safe to proceed.*

![ArgoCD login page](docs/screenshots/40-argocd-login-page.png)
*ArgoCD login page — accessible at https://63.184.235.88:30080*

![ArgoCD dashboard](docs/screenshots/41-argocd-dashboard.png)
*ArgoCD dashboard — no applications yet. The GitOps engine is running and waiting for its first app definition.*

**What this teaches:** ArgoCD's install manifest includes CRDs large enough to break the default kubectl apply path — a well-known issue with CRD-heavy operators. The fix (server-side apply with force-conflicts) is the documented solution and is now standard practice for any large CRD installation. Running this through Ansible means the fix is captured in code and never needs to be rediscovered.

---

### Deploying Online Boutique — Helm and GitOps

With ArgoCD running, the next step is deploying the application. This required two decisions: how to package the application for Kubernetes, and where that package should live.

#### What is Helm?

Helm is the package manager for Kubernetes. Raw Kubernetes manifests are static — every value is hardcoded. Helm introduces templates with variables:

```yaml
# Raw manifest — hardcoded, cannot change without editing the file
image: us-central1-docker.pkg.dev/google-samples/frontend:v0.10.1

# Helm template — variable, controlled by values.yaml
image: {{ .Values.images.repository }}/frontend:{{ .Values.images.tag }}
```

A single `values.yaml` controls the entire deployment:

```yaml
images:
  repository: 123456789.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce
  tag: "abc123f"   ← Jenkins writes this after every build
```

One chart, one `values.yaml` — different values for different environments. `values.yaml` is also the handoff point between Jenkins (CI) and ArgoCD (CD): Jenkins builds an image, pushes it to ECR, writes the new tag into `values.yaml`, commits to GitHub. ArgoCD detects the commit and deploys.

#### Why the Helm Chart Lives in Our Repo

The first instinct was to point ArgoCD at Google's public microservices-demo repository and use their Helm chart directly. This is a shortcut that removes a critical step:

- Google's chart uses Google's image registry — not our ECR
- Google could change their chart without warning and break the deployment
- `values.yaml` must be in our repo — it's where Jenkins writes the new image tag
- The chart is infrastructure code — it belongs under version control in our project alongside the Ansible playbooks and Terraform modules

The correct approach: copy the Helm chart into our repo and own it.

```
kubernetes/
└── apps/
    └── online-boutique/
        ├── Chart.yaml      ← chart name, version, metadata
        ├── values.yaml     ← our config — image registry, replicas, resources
        └── templates/      ← all 12 service definitions as Helm templates
```

![Helm chart structure](docs/screenshots/42-helm-chart-structure.png)
*Online Boutique Helm chart in our repo — Chart.yaml, values.yaml, and templates/ all under version control*

![values.yaml](docs/screenshots/44-values-yaml-open.png)
*values.yaml — images.repository points to Google's registry now, will be updated to ECR once Jenkins is building images. The tag field is what Jenkins writes after every build.*

#### Validating the Chart with helm lint

Helm v3 was already installed in WSL — confirmed before running any chart commands:

![helm version](docs/screenshots/42a-helm-version.png)
*helm v3.17.3 confirmed in WSL — ready to lint and template charts locally*

Before committing, the chart was validated locally:

```bash
helm lint kubernetes/apps/online-boutique/
```

```
==> Linting kubernetes/apps/online-boutique/
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

![helm lint pass](docs/screenshots/43-helm-lint-pass.png)
*helm lint — 1 chart linted, 0 failed. Chart is valid and ready to deploy.*

`helm lint` checks that all templates are syntactically valid and all required values are present. The INFO about a missing icon is cosmetic — not an error. Running lint before every commit catches template errors before ArgoCD attempts to render them against the cluster.

The first lint run failed — our initial `values.yaml` was missing the `frontend.virtualService` block that the template expected. The fix was to use Google's complete `values.yaml` as the base and add our ECR comment at the top.

#### The ArgoCD Application Manifest

ArgoCD learns about applications through `Application` manifests — Kubernetes custom resources that tell ArgoCD which Git repo to watch and where to deploy:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: online-boutique
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Dennis4507/cloudcommerce-devops.git
    targetRevision: HEAD
    path: kubernetes/apps/online-boutique
  destination:
    server: https://kubernetes.default.svc
    namespace: online-boutique
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Key fields:
- `repoURL` — our GitHub repo, not Google's
- `path` — where the Helm chart lives inside our repo
- `automated` — ArgoCD syncs automatically on every git commit, no manual trigger needed
- `prune: true` — resources removed from Git are also removed from the cluster
- `selfHeal: true` — if someone manually changes the cluster, ArgoCD reverts it back to match Git
- `CreateNamespace=true` — ArgoCD creates the `online-boutique` namespace automatically

![ArgoCD Application manifest](docs/screenshots/44a-argocd-application-manifest.png)
*kubernetes/argocd/online-boutique.yaml in VS Code — repoURL points at our GitHub repo, path points at our Helm chart, automated sync enabled*

**What this teaches:** `values.yaml` is not configuration to be forgotten after setup — it is the live deployment contract between CI and CD. Every Jenkins build ends with a commit to this file. Every ArgoCD sync starts by reading it. Owning the chart in your own repo means owning the entire deployment lifecycle.

---

### Applying the ArgoCD Application — First Sync

With the Helm chart committed and pushed to GitHub, the ArgoCD Application manifest was applied:

```bash
kubectl apply -f kubernetes/argocd/online-boutique.yaml
```

![kubectl apply ArgoCD app](docs/screenshots/45-kubectl-apply-argocd-app.png)
*kubectl apply — Application resource created in ArgoCD*

ArgoCD detected the new Application immediately and began syncing — pulling the Helm chart from our GitHub repo, rendering all 12 service templates with our values.yaml, and applying them to the `online-boutique` namespace:

![ArgoCD syncing](docs/screenshots/46-argocd-syncing.png)
*ArgoCD showing online-boutique app syncing — Progressing/Synced, pulling from Dennis4507/cloudcommerce-devops*

![ArgoCD tree view](docs/screenshots/47-argocd-tree-view.png)
*ArgoCD application tree — all 12 deployments, services, and service accounts visible*

![ArgoCD tree view 2](docs/screenshots/47a-argocd-tree-view2.png)
*ArgoCD tree view detail — each deployment with its ReplicaSet and running pod*

---

### Challenge: 404 — Traefik vs LoadBalancer

With all pods running, opening `http://63.184.235.88` returned a 404. The issue: the Helm chart creates a `frontend-external` LoadBalancer service for cloud environments where a load balancer is provisioned automatically. On k3s, Traefik already owns port 80 — the LoadBalancer service stayed in `<pending>` indefinitely and ArgoCD reported "Progressing" instead of "Healthy".

```bash
kubectl get svc -n online-boutique
```

![kubectl get svc](docs/screenshots/48-kubectl-get-svc.png)
*frontend-external showing EXTERNAL-IP: pending — LoadBalancer cannot get an IP, Traefik owns port 80*

![404 page](docs/screenshots/49-frontend-404.png)
*http://63.184.235.88 returns 404 — Traefik has no route to the frontend yet*

**Fix — Traefik Ingress:** k3s ships with Traefik as the ingress controller. Instead of a LoadBalancer service, an Ingress resource routes HTTP traffic through Traefik to the frontend pod. A new template was added to the Helm chart:

```yaml
# kubernetes/apps/online-boutique/templates/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: online-boutique
  namespace: {{ .Release.Namespace }}
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
```

![Ingress yaml](docs/screenshots/50-ingress-yaml.png)
*ingress.yaml added to templates/ — routes all port 80 traffic through Traefik to the frontend service*

The chart was validated before committing:

![helm lint ingress](docs/screenshots/51-helm-lint-ingress.png)
*helm lint — 0 failures after adding ingress.yaml*

The `frontend.externalService` value was also set to `false` in `values.yaml` to remove the pending LoadBalancer service and clear the ArgoCD "Progressing" health status:

![externalService false](docs/screenshots/52-externalservice-false.png)
*values.yaml — externalService: false removes the frontend-external LoadBalancer service*

ArgoCD detected both commits and synced automatically. All 12 pods confirmed running:

![kubectl pods running](docs/screenshots/53-kubectl-pods-running.png)
*kubectl get pods -n online-boutique — all 12 pods Running 1/1*

![ArgoCD healthy](docs/screenshots/54-argocd-healthy.png)
*ArgoCD showing APP HEALTH: Healthy, SYNC STATUS: Synced — all resources reconciled*

---

### Online Boutique — Live

With Traefik routing traffic correctly, `http://63.184.235.88` loaded the full e-commerce application:

![Online Boutique live](docs/screenshots/55-online-boutique-live.png)
*Online Boutique homepage — 12 microservices serving a live e-commerce storefront on k3s*

![Online Boutique products](docs/screenshots/55a-online-boutique-products.png)
*Product catalogue — sunglasses, clothing, watches served by the productcatalogservice microservice*

![Online Boutique cart](docs/screenshots/55b-online-boutique-cart.png)
*Shopping cart — cartservice handling session state via Redis*

![Order complete](docs/screenshots/56-order-complete.png)
*Order confirmed — all 12 microservices working end to end: frontend → checkout → payment → email*

The full GitOps pipeline is proven: a git commit to the infrastructure repo triggered ArgoCD to deploy a live, functional 12-microservice application accessible from the public internet.

---

### Jenkins Credentials — Securing Pipeline Secrets

With the application running, Jenkins was configured to build and push images to ECR. All sensitive values are stored in Jenkins' built-in credentials store — never in Jenkinsfiles or logs.

Two credentials were added:

**1 — GitHub Personal Access Token** — allows Jenkins to commit the updated `values.yaml` back to GitHub after each build:

![GitHub token creation](docs/screenshots/57-github-token-creation.png)
*GitHub classic personal access token — repo scope only, named Jenkins CloudCommerce*

![Jenkins credentials form](docs/screenshots/58-jenkins-credentials-form.png)
*Jenkins credentials form — token added as Username with password type*

**2 — AWS Account ID** — used to construct the ECR registry URL in the pipeline:

![Jenkins credentials complete](docs/screenshots/59-jenkins-credentials-complete.png)
*Jenkins Globale Zugangsdaten — both credentials in place: github-token and aws-account-id*

Jenkins uses the EC2 instance's IAM role for ECR authentication — no AWS access keys stored anywhere. The IAM role was provisioned by Terraform in Phase 1 with the exact permissions needed.

---

### Application Repository — microservices-demo

The Jenkinsfile belongs in the application repository, not the infrastructure repository. A separate GitHub repo was created for the application source:

**`Dennis4507/microservices-demo`** — the application code Jenkins builds from

This separates concerns correctly:
- `Dennis4507/cloudcommerce-devops` — infrastructure, Helm charts, Ansible, Terraform (DevOps team)
- `Dennis4507/microservices-demo` — application source code (development team)

Google's CI workflows (`.github/workflows/`) were removed — Jenkins replaces them:

![microservices-demo push](docs/screenshots/60-microservices-demo-push.png)
*Google's GitHub Actions workflows removed, microservices-demo pushed to Dennis4507's GitHub — Jenkins owns CI from here*

---

### Progress
- [x] k3s installed via Ansible — single-binary Kubernetes on EC2 t3.medium
- [x] TLS SAN challenge diagnosed and resolved — public Elastic IP added to certificate via `--tls-san`
- [x] kubectl installed and configured — remote cluster access from local machine confirmed
- [x] k9s v0.50.18 installed — terminal UI showing all 7 system pods Running
- [x] kubectl PATH made permanent on Windows — works across all terminal sessions
- [x] ArgoCD installed via Ansible — two kubectl apply challenges diagnosed and resolved
- [x] ArgoCD UI accessible at https://63.184.235.88:30080 — GitOps engine live
- [x] Online Boutique Helm chart copied into repo — chart validated with helm lint
- [x] ArgoCD Application manifest created and applied — all 12 services deployed
- [x] Traefik Ingress configured — 404 resolved, site live at http://63.184.235.88
- [x] Online Boutique fully functional — products, cart, and checkout all working
- [x] Jenkins credentials configured — GitHub token and AWS account ID secured
- [x] Application repo created — Dennis4507/microservices-demo owns the application source
- [x] Install Trivy and AWS CLI on Jenkins server via Ansible — two bugs diagnosed and fixed
- [ ] Create Jenkins pipeline job pointing at microservices-demo
- [ ] Configure GitHub webhook → Jenkins trigger
- [ ] Run first full pipeline build → ECR → values.yaml update → ArgoCD deploy

---

### Installing Trivy and AWS CLI — Session Management and Silent Failures

With the Online Boutique live and credentials configured, the final step before running the Jenkins pipeline was installing two tools on the Jenkins server: Trivy (image scanner) and AWS CLI (ECR authentication). This exposed two separate problems that required diagnosis and playbook fixes.

#### Stop/Start Discipline — EC2 Instance Management

Instances are stopped between working sessions and started again when needed. This keeps running costs near zero — AWS charges nothing for stopped EC2 instances — while Elastic IPs ensure the addresses never change.

![Stop instances](docs/screenshots/61-stop-instances.png)
*Instances stopped at end of session — "Successfully initiated stopping" confirmation in AWS console*

![Instances stopped](docs/screenshots/62-instances-stopped.png)
*AWS console filtered by instance state = stopped — both Jenkins and k3s instances off*

At the start of the next session, both instances are started together:

![Start instances](docs/screenshots/63-start-instances.png)
*Both instances successfully started — AWS console showing running state restored*

---

#### Challenge 1 — Ansible Playbook Stuck: t2.micro Memory Constraint

The Ansible playbook ran but hung at "Install Java 21 and dependencies" — the terminal showed no progress for minutes. SSHing into the server and running `free -h` revealed the cause:

```
Mem:   957Mi   697Mi   70Mi   0.0Ki   188Mi   100Mi
Swap:     0B     0B    0B
```

Only 100MB available, no swap. Jenkins JVM was holding ~600MB of the 1GB total. With so little free memory, apt could not spawn the processes needed to install packages — even `java --version` hung when run interactively.

**Fix:** Stop Jenkins first to free ~400MB, then run the playbook:

```bash
sudo systemctl stop jenkins
```

![Stop Jenkins to free memory](docs/screenshots/64-stop-jenkins-free-memory.png)
*Jenkins stopped — free -h shows 573MB available, plenty of headroom for apt to work*

This is a known constraint of the t2.micro (1GB RAM). Jenkins is fine for running pipelines, but system maintenance must be done with Jenkins stopped. The pattern: stop Jenkins → run Ansible → Jenkins restarts automatically at the end of the playbook.

---

#### Challenge 2 — Ansible Reported Success but AWS CLI Was Not Installed

With Jenkins stopped, the playbook ran and reported `changed=4, failed=1`. The failure was the initial admin password task — but more importantly, even though "Install AWS CLI" showed `changed` (meaning Ansible believed it succeeded), running `aws --version` on the server returned command not found.

![Ansible password task failed](docs/screenshots/65-ansible-password-task-failed.png)
*Ansible output — ok=12, changed=4, failed=1. AWS CLI shows changed but the binary does not exist*

This is a silent failure — Ansible reported success for a task that did not actually complete. The root cause: the AWS CLI install script requires `unzip` to extract the downloaded zip file, but `unzip` was not installed on the server.

```bash
curl ...           # downloads the zip — succeeds
unzip ...          # FAILS — unzip not installed
/tmp/aws/install   # never runs
rm -rf ...         # always succeeds — exit code 0
```

Because bash only checks the exit code of the **last command**, and `rm -rf` always exits 0, Ansible saw success. The actual failure was invisible.

![AWS CLI unzip bug](docs/screenshots/67-awscli-unzip-bug.png)
*Old playbook — unzip missing from dependencies, AWS CLI install silently fails at extraction step*

---

#### Fix 1 — Playbook Crash on Missing Password File

The separate `failed=1` was the "Get Jenkins initial admin password" task trying to read a file that only exists on first-time Jenkins setup. Since Jenkins was already configured, the file was long gone. The fix — `failed_when: false` — tells Ansible not to crash when the file is absent:

```yaml
- name: Get Jenkins initial admin password
  command: cat /var/lib/jenkins/secrets/initialAdminPassword
  register: jenkins_password
  changed_when: false
  failed_when: false    ← file not found is acceptable after first setup
```

![failed_when false fix](docs/screenshots/66-failed-when-false-fix.png)
*VS Code diff — failed_when: false added, default message updated to explain the missing file*

---

#### Fix 2 — AWS CLI Silent Failure

Three changes to the playbook fixed the silent AWS CLI failure:

**1 — Add `unzip` to dependencies** so it is always present before the install script runs:

```yaml
- name: Install Java 21 and dependencies
  apt:
    name:
      - openjdk-21-jdk
      - curl
      - gnupg
      - unzip          ← added
```

**2 — Add `set -e`** to the shell script so any step failure stops the script immediately and Ansible reports a real error:

```yaml
- name: Install AWS CLI
  shell: |
    set -e             ← stops on any failure, no more silent passes
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws
```

**3 — Add a cleanup task** to remove any leftover files from the previous failed attempt before retrying:

```yaml
- name: Clean up any partial AWS CLI install
  file:
    path: "{{ item }}"
    state: absent
  loop:
    - /tmp/awscliv2.zip
    - /tmp/aws
```

![AWS CLI unzip fix explained](docs/screenshots/68-awscli-unzip-fix.png)
*New playbook — unzip added to dependencies, cleanup task added before install*

![AWS CLI set -e fix](docs/screenshots/69-awscli-set-e-fix.png)
*set -e and cleanup task in context — any step failure now surfaces immediately*

![Playbook AWS CLI updated in VS Code](docs/screenshots/70-playbook-awscli-updated.png)
*setup-jenkins.yml in VS Code — updated Install AWS CLI task with set -e and correct unzip*

![Playbook failed_when false in VS Code](docs/screenshots/71-playbook-failed-when-false.png)
*setup-jenkins.yml in VS Code — failed_when: false on password task and default message*

---

#### Final Playbook Run — Full Success

With both fixes applied, the playbook ran cleanly: 15 tasks, 4 changed, 0 failed:

![Ansible Jenkins full success](docs/screenshots/72-ansible-jenkins-full-success.png)
*Full successful run — ok=15, changed=4, failed=0. AWS CLI installed, Trivy confirmed, Jenkins started*

AWS CLI verified on the server:

![AWS CLI verified](docs/screenshots/73-aws-cli-verified.png)
*aws --version confirms aws-cli/2.34.51 installed and available — Jenkins is now ready to authenticate to ECR*

**What this teaches:**

- `changed` in Ansible means the task ran — it does not guarantee the task did what you intended. Always verify the actual outcome on the server
- `shell` tasks only see the exit code of the last command. Add `set -e` to any multi-step shell script so failures surface immediately
- Use Ansible's built-in modules (`apt`, `systemd`, `file`) wherever possible — they handle error detection and idempotency automatically. Use `shell` only when no module exists, and always add `set -e`
- On memory-constrained servers (t2.micro, 1GB RAM), stop memory-hungry services before running system maintenance. Jenkins JVM holds ~600MB — leaving no room for apt to operate

---

### Progress
- [x] k3s installed via Ansible — single-binary Kubernetes on EC2 t3.medium
- [x] TLS SAN challenge diagnosed and resolved — public Elastic IP added to certificate via `--tls-san`
- [x] kubectl installed and configured — remote cluster access from local machine confirmed
- [x] k9s v0.50.18 installed — terminal UI showing all 7 system pods Running
- [x] kubectl PATH made permanent on Windows — works across all terminal sessions
- [x] ArgoCD installed via Ansible — two kubectl apply challenges diagnosed and resolved
- [x] ArgoCD UI accessible at https://63.184.235.88:30080 — GitOps engine live
- [x] Online Boutique Helm chart copied into repo — chart validated with helm lint
- [x] ArgoCD Application manifest created and applied — all 12 services deployed
- [x] Traefik Ingress configured — 404 resolved, site live at http://63.184.235.88
- [x] Online Boutique fully functional — products, cart, and checkout all working
- [x] Jenkins credentials configured — GitHub token and AWS account ID secured
- [x] Application repo created — Dennis4507/microservices-demo owns the application source
### Creating the Jenkins Pipeline Job

With Trivy and AWS CLI installed, Jenkins was ready to run the pipeline. A pipeline job was created in the Jenkins UI pointing at the `microservices-demo` application repository.

**Job configuration:**
- **Type:** Pipeline
- **Trigger:** GitHub hook trigger for GITScm polling — Jenkins listens for webhook events from GitHub
- **Definition:** Pipeline script from SCM — Jenkins reads the Jenkinsfile from the repository, not from the UI
- **SCM:** Git
- **Repository:** `https://github.com/Dennis4507/microservices-demo.git`
- **Credentials:** None — the repo is public, no authentication needed to clone
- **Branch:** `*/main`
- **Script Path:** `Jenkinsfile`

![Jenkins pipeline config](docs/screenshots/74-jenkins-pipeline-config.png)
*cloudcommerce-frontend pipeline job — GitHub hook trigger enabled, Pipeline script from SCM pointing at microservices-demo*

![Jenkins pipeline setup](docs/screenshots/98-jenkins-pipeline-setup.png)
*Jenkins Configure page — "GitHub hook trigger for GITScm polling" enabled (checked) so every git push fires a build, and Pipeline definition set to "Pipeline script from SCM" so Jenkins reads the Jenkinsfile from the repository*

![Jenkins cloudcommerce frontend job](docs/screenshots/99-jenkins-cloudcommerce-frontend.png)
*Jenkins main dashboard — cloudcommerce-frontend pipeline job listed with a build in progress (blue spinner), no successful or failed builds yet since it was just created*

**Why Pipeline script from SCM instead of writing the script in the UI?**

The Jenkinsfile lives in the same repository as the application code. This means:
- Pipeline changes are reviewed alongside application changes
- The pipeline is version controlled — you can see exactly what changed and when
- Any developer cloning the repo gets the pipeline definition automatically
- Jenkins always runs the pipeline version that matches the code being built

Writing the pipeline directly in the Jenkins UI would mean it lives only in Jenkins — invisible to git, unreviewed, and disconnected from the code it builds.

---

### GitHub Webhook — Instant Trigger on Push

A webhook was configured on the `microservices-demo` repository so that every `git push` immediately triggers a Jenkins build — no polling delay.

**Webhook settings:**
- **Payload URL:** `http://3.127.90.169:8080/github-webhook/`
- **Content type:** `application/json`
- **Events:** Push only

![GitHub webhook setup](docs/screenshots/75-github-webhook-setup.png)
*GitHub webhook form — Payload URL pointing at Jenkins, application/json content type, push events only*

![Setting up GitHub webhooks](docs/screenshots/96-setting-up-github-webhooks.png)
*Webhook configuration in GitHub — Payload URL and content type filled in before saving*

![GitHub webhook success](docs/screenshots/76-github-webhook-success.png)
*Webhook confirmed — green tick, "Last delivery was successful"*

![GitHub webhook delivery success](docs/screenshots/97-github-webhook-delivery-success.png)
*GitHub Webhooks page — green checkmark and "Last delivery was successful" confirms Jenkins received and processed the push event from GitHub*

**Without the webhook:** Jenkins would poll GitHub every few minutes — there would be a delay between pushing code and the build starting.

**With the webhook:** GitHub sends a POST request to Jenkins the instant a push happens. The build starts within seconds.

---

### First Build — Triggered by Webhook

The webhook was tested immediately by pushing a small change to `microservices-demo`:

```bash
echo "# CloudCommerce CI/CD" >> README.md
git add README.md
git commit -m "ci: trigger first Jenkins build"
git push
```

![Trigger test build](docs/screenshots/95-trigger-test-build.png)
*WSL terminal — making a small change to microservices-demo and pushing to trigger the Jenkins webhook and start build #1*

![Trigger first build](docs/screenshots/77-trigger-first-build-push.png)
*WSL terminal — git push to microservices-demo triggers the GitHub webhook, Jenkins receives the event and starts build #1*

Jenkins received the webhook and started build #1 immediately:

![Jenkins dashboard job](docs/screenshots/78-jenkins-dashboard-job.png)
*Jenkins dashboard — cloudcommerce-frontend job visible, build #1 in progress*

![Jenkins build loading](docs/screenshots/79-jenkins-build-loading.png)
*Jenkins job page loading — the UI is slow because Jenkins JVM is actively running the build on a 1GB t2.micro*

![Jenkins build running](docs/screenshots/80-jenkins-build-running.png)
*Build #1 running — started 10 minutes ago, Docker image compilation in progress*

![Jenkins building](docs/screenshots/100-jenkins-building.png)
*Jenkins cloudcommerce-frontend build #1 — started 10 minutes ago, progress bar still running, no estimated finish time (the Go compiler is using all available RAM and the build is effectively stalled)*

![Jenkins webhook received slow](docs/screenshots/94-jenkins-webhook-received-slow.png)
*Jenkins cloudcommerce-frontend job page — Jenkins received the build via the GitHub webhook (Last Build #1 visible) but the builds list is still "Loading..." because the server is too slow to respond; the browser tab is still spinning*

The build console confirmed the full pipeline in motion:
- ✅ Webhook fired by GitHub push
- ✅ Jenkinsfile read from `microservices-demo` repository
- ✅ Image tag set to `9f2ba8cf` (git commit short hash)
- ✅ ECR login succeeded — IAM instance profile authentication working
- ✅ Docker build started — Go frontend binary compiling from source

---

### Progress
- [x] Trivy installed on Jenkins server — image scanning ready
- [x] AWS CLI installed on Jenkins server — ECR authentication ready
- [x] t2.micro memory constraint understood — stop Jenkins before system maintenance
---

### Incident 1 — Jenkins Server Ran Out of Memory (OOM Crash)

**What happened — in simple terms:**

Think of RAM (memory) like a desk. The more things you have open on your desk, the more space you need. Our Jenkins server had a small desk (1GB RAM). Jenkins itself was already taking up most of it. When the pipeline started building the frontend — which involves compiling Go code, a heavy task — there was no room left. The operating system, unable to fit everything, started forcibly closing programs to survive. The build died silently. The server became unresponsive.

**The technical detail:**

The t2.micro instance has 1GB RAM and no swap space. Jenkins JVM holds ~600MB at runtime. The Go compiler needs ~400-500MB to compile the frontend service. 600 + 500 = 1100MB — more than the 1000MB available. The Linux OOM (Out of Memory) killer terminated the Go compiler process. Jenkins was left waiting for a process that was already dead. The server became too memory-starved to even serve the web UI.

![Jenkins sluggish webhook](docs/screenshots/81-jenkins-sluggish-webhook.png)
*Jenkins build #1 Changes tab — page is blank with a loading spinner, taking too long to load after the webhook triggered the build; the t2.micro had no memory left during Go compilation*

![OOM diagnosis](docs/screenshots/82-oom-diagnosis.png)
*WSL terminal during the OOM incident — SSH into Jenkins hangs and has to be cancelled (^C) because the server is too memory-starved to respond; this confirmed the server was unreachable without a reboot*

**How it was diagnosed:**

```bash
free -h
# available: 100Mi  ← only 100MB free while build was running
# available: 70Mi   ← server nearly unresponsive
```

After the server stopped responding to SSH entirely, the instance was rebooted from the AWS console.

![Reboot instance](docs/screenshots/83-reboot-instance.png)
*AWS console — Reboot Instance used to bring Jenkins back after OOM kill made SSH impossible*

![Server back low memory](docs/screenshots/84-server-back-low-memory.png)
*Server is back — only 262MB available even at idle with Jenkins running, confirming the root cause: this server cannot build Go code while Jenkins is running*

**The fix — upgrade Jenkins to t3.medium via Terraform:**

The Jenkins instance type was changed from `t2.micro` (1GB RAM) to `t3.medium` (4GB RAM) in one line of Terraform:

```hcl
# variables.tf — before
variable "jenkins_instance_type" {
  default = "t2.micro"   ← 1GB RAM, no headroom for builds
}

# variables.tf — after
variable "jenkins_instance_type" {
  default = "t3.medium"  ← 4GB RAM, plenty for Jenkins + Docker builds
}
```

![Terraform t3medium plan](docs/screenshots/85-terraform-t3medium-plan.png)
*VS Code showing variables.tf with jenkins_instance_type changed to t3.medium — running terraform apply will stop Jenkins, resize it from t2.micro to t3.medium, and restart it; the Elastic IP stays the same so nothing else changes*

![Jenkins t3medium confirmed](docs/screenshots/86-jenkins-t3medium-confirmed.png)
*Jenkins is now on t3.medium (4GB RAM) — AWS console confirms the instance type change*

This led directly to Incident 2.

---

### Incident 2 — Terraform Destroyed Both Servers (AMI Change)

**What happened — in simple terms:**

Imagine you ask a builder to renovate your kitchen. You say "use the latest tiles available." The builder goes to the shop and finds that the tiles you used when you first built the house are no longer the latest model — a new version was released last week. The builder decides the only way to put in the new tiles is to demolish the kitchen and rebuild it from scratch. You lose everything in the kitchen.

That is exactly what Terraform did. Both servers were demolished and rebuilt from scratch.

**The technical detail:**

Our Terraform code used `most_recent = true` in the AMI data source — meaning "always use the latest Ubuntu image from AWS." Between when we first built the servers and now, AWS published a new Ubuntu AMI:

```
Old AMI: ami-0f7804991cb8f07c4   ← what our servers were running on
New AMI: ami-0c905937c14bd22b0   ← what AWS published recently
```

Terraform detected the new AMI and determined it needed to replace both instances. In the plan output, this appeared as:

```
# module.ec2.aws_instance.jenkins must be replaced
-/+ resource "aws_instance" "jenkins" {
      ~ ami = "ami-0f7804991cb8f07c4" -> "ami-0c905937c14bd22b0" # forces replacement
```

![Jenkins must replace](docs/screenshots/89-jenkins-must-replace.png)
*Terraform plan — `module.ec2.aws_instance.jenkins must be replaced` with -/+ symbol clearly visible*

![Terraform forces replacement Jenkins](docs/screenshots/87-terraform-forces-replacement-jenkins.png)
*Plan detail for Jenkins instance — `# forces replacement` next to the AMI change line*

![Terraform forces replacement k3s](docs/screenshots/88-terraform-forces-replacement-k3s.png)
*Plan detail for k3s instance — same AMI change forcing replacement on the second server too*

The `-/+` symbol and `# forces replacement` were the warning signs. The plan was approved without fully reading it, and both servers were destroyed.

![Apply 2 destroyed](docs/screenshots/90-apply-2-destroyed.png)
*Apply complete — 2 added, 2 changed, 2 destroyed. Both servers are gone.*

![New instances after destroy](docs/screenshots/91-new-instances-after-destroy.png)
*AWS EC2 console — two fresh instances running after Terraform rebuilt them from scratch. All installed software is gone.*

**The warning signs that should have stopped the apply:**

| Symbol | Meaning | Action |
|---|---|---|
| `+` | Create new resource | Generally safe |
| `~` | Update existing resource | Generally safe |
| `-` | Destroy resource | Stop and read carefully |
| `-/+` | Destroy then recreate | **Stop. Read everything. Ask why.** |

**The fix — `lifecycle { ignore_changes = [ami] }`:**

This tells Terraform: "even if a new AMI is published, do not recreate the instance because of it." AMI updates on running servers are handled through Ansible, not by destroying and rebuilding.

```hcl
resource "aws_instance" "jenkins" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.jenkins_instance_type

  lifecycle {
    ignore_changes = [ami]   ← never destroy the server just because a new AMI exists
  }
}
```

![Lifecycle fix Jenkins](docs/screenshots/92-lifecycle-fix-jenkins.png)
*`lifecycle { ignore_changes = [ami] }` added to the Jenkins instance in terraform/modules/ec2/main.tf — Terraform will never destroy this instance due to an AMI change again*

![Lifecycle fix k3s](docs/screenshots/93-lifecycle-fix-k3s.png)
*Same lifecycle fix applied to the k3s instance — both servers now protected from AMI-triggered replacement*

This fix was applied to both the Jenkins and k3s instance resources immediately after the incident.

---

### Why This Incident is Valuable — Infrastructure as Code in Action

**The silver lining:** Both servers were rebuilt and fully operational again within a few hours. Not because of luck — because every installation step was already written as Ansible playbooks.

Without IaC, rebuilding would mean:
- Remembering every package installed over weeks of work
- Clicking through AWS consoles
- Re-entering every configuration manually
- Hours or days of work with no guarantee of matching the original

With IaC, rebuilding means:
```bash
ansible-playbook setup-jenkins.yml   # Jenkins + Trivy + AWS CLI back in minutes
ansible-playbook setup-k3s.yml       # k3s Kubernetes cluster back in minutes
ansible-playbook setup-argocd.yml    # ArgoCD GitOps engine back in minutes
kubectl apply -f kubernetes/argocd/  # Online Boutique redeployed from Git
```

Everything was back because everything was in code. The servers are disposable. The code is permanent.

**This is exactly why Infrastructure as Code exists.** Not to prevent mistakes — mistakes happen. But to make recovery fast, consistent, and complete.

---

### Recovery Plan — Rebuilding After the Terraform Incident

Both servers are fresh Ubuntu with only Docker installed (from the Terraform user_data script). Everything else needs to be reinstalled via Ansible playbooks.

**Step 1 — Reinstall Jenkins (with Trivy and AWS CLI):**
```bash
ansible-playbook -i inventory/hosts playbooks/setup-jenkins.yml \
  --private-key ~/.ssh/cloudcommerce-dev-key -u ubuntu
```

**Step 2 — Reconfigure Jenkins in the UI:**
- Unlock with initial admin password
- Install suggested plugins
- Create admin account
- Add credentials (aws-account-id, github-token)
- Create cloudcommerce-frontend pipeline job
- Re-enable GitHub webhook trigger

**Step 3 — Reinstall k3s:**
```bash
ansible-playbook -i inventory/hosts playbooks/setup-k3s.yml \
  --private-key ~/.ssh/cloudcommerce-dev-key -u ubuntu
```

**Step 4 — Reinstall ArgoCD:**
```bash
ansible-playbook -i inventory/hosts playbooks/setup-argocd.yml \
  --private-key ~/.ssh/cloudcommerce-dev-key -u ubuntu
```

**Step 5 — Redeploy Online Boutique:**
```bash
kubectl apply -f kubernetes/argocd/online-boutique.yaml
```
ArgoCD detects the manifest and automatically syncs the Helm chart from GitHub. The application is back within minutes.

**Step 6 — Retry the Jenkins pipeline build:**

Push any change to `microservices-demo` to trigger the webhook. This time Jenkins has 4GB RAM — the Go compilation completes without OOM.

---

### Incident 3 — Jenkins Reinstallation: GPG Key Mismatch

After the Terraform AMI incident destroyed both servers, the Jenkins Ansible playbook was run to rebuild from scratch. It failed four times in a row before succeeding. Here is exactly what happened and why.

**What happened — in simple terms:**

When Ubuntu installs software from a third-party source like Jenkins, it first asks: "can I trust this source?" To answer that, it checks a digital stamp called a GPG key — like a wax seal on an envelope proving the letter is genuine. If the seal doesn't match, Ubuntu refuses to open the envelope and install anything.

We had the right envelope (Jenkins repository) but kept presenting the wrong stamp. Ubuntu refused every time.

**The four failed attempts:**

**Attempt 1 — Original playbook, keyserver method:**

The playbook fetched the Jenkins key from a public key directory (keyserver.ubuntu.com) and stored it in a custom file. The key was imported but in the wrong format — like a photocopy of a stamp instead of the real one. Ubuntu checked it and rejected it.

![Ansible Jenkins GPG error 1](docs/screenshots/101-ansible-jenkins-gpg-error-1.png)
*First Ansible run — `failed=1` at the Update apt cache step; Ubuntu refuses to trust the Jenkins repository because the GPG key format is wrong*

**Attempt 2 — Reordered playbook, same key method:**

The tasks were reordered so the key import happened before the Java installation (to stop the failed apt update blocking Java). The key was still wrong. Same error.

![Ansible Jenkins GPG error 2](docs/screenshots/102-ansible-jenkins-gpg-error-2.png)
*Second attempt — same `NO_PUBKEY 7198F4B714ABFC68` error; reordering tasks fixed the sequence but not the underlying key mismatch*

**Attempt 3 — Downloaded key directly from Jenkins website (armored format):**

Instead of the keyserver, the key was downloaded straight from Jenkins' own website (`jenkins.io-2023.key`) and saved as `.asc` format. The download succeeded but the key in that file had a **different ID** than the one Jenkins used to sign their packages. Ubuntu compared the two — they didn't match — and refused again.

![Playbook GPG armored fix](docs/screenshots/105-playbook-gpg-armored-fix.png)
*VS Code showing the playbook update — switching from keyserver to direct download from Jenkins' website in an attempt to fix the key mismatch*

![Ansible Jenkins GPG error 3](docs/screenshots/103-ansible-jenkins-gpg-error-3.png)
*Third attempt — key downloaded successfully but still wrong ID; the `jenkins.io-2023.key` file contains a different key than the one that signed the stable repository*

**Attempt 4 — Downloaded and converted the key (dearmor):**

The same key was downloaded and run through a conversion tool (`gpg --dearmor`) to change its format. The format was still wrong and the key ID was still the wrong one.

![Playbook GPG direct download fix](docs/screenshots/106-playbook-gpg-direct-download-fix.png)
*VS Code diff — the playbook change showing the direct download + dearmor conversion attempt. Red lines removed, green lines added.*

![Ansible Jenkins GPG error 4](docs/screenshots/104-ansible-jenkins-gpg-error-4.png)
*Fourth attempt — still `NO_PUBKEY 7198F4B714ABFC68`; converting the key format did not help because the key ID itself was wrong*

**The fix — fetch the exact key by its ID:**

Instead of guessing which file contained the right key, the playbook was updated to tell Ubuntu: "go and fetch exactly key number `7198F4B714ABFC68` from the Ubuntu key directory — the same key Jenkins used to sign their packages." Ubuntu fetched that exact key, matched it to the Jenkins repository signature, and accepted it.

```yaml
- name: Import Jenkins GPG key by exact key ID
  shell: |
    gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 7198F4B714ABFC68
    gpg --batch --export --armor 7198F4B714ABFC68 > /usr/share/keyrings/jenkins-keyring.asc
```

**Why this happened now but not before:** The newer Ubuntu AMI (created after the Terraform incident) has a stricter version of apt that verifies the key ID more precisely. The original server was more lenient. Same principle, tighter enforcement.

![Ansible Jenkins success](docs/screenshots/107-ansible-jenkins-success.png)
*Fifth attempt — `ok=15, changed=7, failed=0`. Jenkins, Trivy, and AWS CLI all installed successfully. Initial admin password printed (redacted).*

---

### Jenkins UI Setup After Reinstallation

With Jenkins installed and running, the browser was opened at `http://3.127.90.169:8080`. The initial setup wizard appeared.

**Step 1 — Install suggested plugins:**

![Jenkins welcome install plugins](docs/screenshots/108-jenkins-welcome-install-plugins.png)
*Jenkins first-run wizard — "Install suggested plugins" selected. This installs Git, Pipeline, GitHub integration, and Credentials in one click.*

![Jenkins suggested plugins installing](docs/screenshots/109-jenkins-suggested-plugins-installing.png)
*Plugins installing — green checkmarks appearing as each plugin completes. Pipeline, Git, GitHub Branch Source, and all core plugins installed successfully.*

**Step 2 — Install Docker Pipeline plugin:**

The suggested plugin set does not include the Docker Pipeline plugin, which our Jenkinsfile needs to build Docker images inside the pipeline. It was installed separately from the Plugin Manager.

![Docker Pipeline plugin installed](docs/screenshots/111-docker-pipeline-plugin-installed.png)
*Plugin Manager — Docker Pipeline showing "Erfolgreich" (Success). All plugins Jenkins needs for our CI/CD pipeline are now installed.*

**Step 3 — Log in to Jenkins dashboard:**

After creating an admin account, Jenkins is fully operational and ready for the pipeline job to be recreated.

![Jenkins dashboard logged in](docs/screenshots/110-jenkins-dashboard-logged-in.png)
*Jenkins dashboard — "Willkommen bei Jenkins!" (Welcome to Jenkins!). Clean dashboard, no jobs yet. Ready to recreate the cloudcommerce-frontend pipeline.*

---

### Progress
- [x] Jenkins pipeline job created — cloudcommerce-frontend pointing at microservices-demo
- [x] GitHub webhook configured — push to microservices-demo triggers Jenkins instantly
- [x] OOM crash diagnosed — Jenkins server ran out of memory during Go compilation
- [x] Terraform AMI incident — both servers accidentally destroyed and recreated, lifecycle fix applied
- [x] Jenkins reinstalled via Ansible — GPG key mismatch resolved after 4 failed attempts
- [x] Jenkins UI configured — suggested plugins, Docker Pipeline, admin account created
- [x] Add Jenkins credentials — GitHub token and AWS account ID
- [x] Recreate cloudcommerce-frontend pipeline job
- [x] Root cause diagnosed — Jenkins was actually running on t2.micro, not t3.medium
- [x] Instance resized to t3.medium — first successful pipeline build completed
- [ ] Rebuild k3s via Ansible playbook
- [ ] Reinstall ArgoCD
- [ ] Redeploy Online Boutique via ArgoCD
- [ ] Run first full end-to-end pipeline → ECR → ArgoCD → k3s deploy

---

### Jenkins Credentials — Restored After Reinstallation

With Jenkins reinstalled and configured, both pipeline credentials were added to the Jenkins credential store under **Global** scope (not System scope — System scope limits credentials to Jenkins internals only, Global makes them available to pipeline jobs):

**1 — AWS Account ID** (`aws-account-id`) — Secret Text. Used to construct the ECR registry URL:
```
<account-id>.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend
```

**2 — GitHub Personal Access Token** (`github-token`) — Username with Password. Jenkins uses this to clone `cloudcommerce-devops` and push the updated `values.yaml` back to GitHub after every build.

![Jenkins credentials configured](docs/screenshots/04_jenkins_credentials.png)
*Globale Zugangsdaten — both credentials in place: github-token and aws-account-id under Global scope. Jenkins authenticates to ECR via IAM role — no AWS keys stored anywhere.*

---

### Recreating the cloudcommerce-frontend Pipeline Job

The pipeline job was recreated pointing at `microservices-demo`:

- **Type:** Pipeline
- **Trigger:** GitHub hook trigger for GITScm polling — Jenkins listens for webhook events from GitHub
- **Definition:** Pipeline script from SCM — Jenkins reads the Jenkinsfile directly from the repository on every build
- **Repository:** `https://github.com/Dennis4507/microservices-demo.git`
- **Branch:** `*/main`

![Jenkins pipeline from SCM](docs/screenshots/05_jenkins_pipeline_from_scm.png)
*Pipeline configuration — "Pipeline script from SCM" selected. The Jenkinsfile lives in the same repository as the application code. Pipeline changes are reviewed alongside code changes, version controlled, and always match the code being built.*

![Pipeline job created](docs/screenshots/06_pipeline_job_created.png)
*cloudcommerce-frontend pipeline job created — ready to receive GitHub webhook events*

The GitHub webhook was recreated on `microservices-demo`:

![GitHub webhook created](docs/screenshots/07_github_webhook_created.png)
*GitHub webhook — Payload URL: `http://3.127.90.169:8080/github-webhook/`, push events only. Every git push immediately triggers a Jenkins build with no polling delay.*

![Microservices demo Jenkinsfile](docs/screenshots/08_microservices_demo_jenkinsfile.png)
*Jenkinsfile in Dennis4507/microservices-demo — defines all 5 pipeline stages: Checkout, Build Image, Scan with Trivy, Push to ECR, Update values.yaml*

---

### Build #1 — Triggered, Then Server Became Unresponsive

A small test change was committed and pushed to `microservices-demo` to trigger the first build:

```html
<!-- CloudCommerce pipeline test v1 -->
```

Jenkins received the webhook and build #1 started within seconds:

![Pipeline triggered](docs/screenshots/09_pipeline_triggered.png)
*Build #1 triggered by GitHub push — webhook working, Jenkinsfile read from repository*

![Pipeline build running](docs/screenshots/10_pipeline_build_running.png)
*Build #1 in progress — Stage: Build Image, Docker pulling base images and compiling the Go frontend*

![Pipeline running build image stage](docs/screenshots/11_pipeline_running_build_image.png)
*6 minutes in — normal for a first build with no Docker layer cache*

After 6 hours, the Jenkins UI became completely unreachable — `ERR_CONNECTION_TIMED_OUT`. The build had been running the entire time.

![Server down after crash](docs/screenshots/12_server_down_crash.png)
*Jenkins UI unreachable — ERR_CONNECTION_TIMED_OUT after 6 hours. The server had become unresponsive under sustained build load.*

The instance was rebooted from the AWS console:

![Stop start explanation](docs/screenshots/13_stop_start_explanation.png)
*Stop → Start chosen over Reboot — forces AWS to provision on fresh underlying hardware and fully clears RAM*

![Instance starting](docs/screenshots/14_instance_starting.png)
*Jenkins instance restarting after Stop → Start*

![Instance back live](docs/screenshots/15_instance_back_live.png)
*Jenkins instance Running — back online*

Reconnecting over SSH required clearing the old host key (Stop → Start changes physical hardware):

![SSH host key changed error](docs/screenshots/16_ssh_host_key_changed_error.png)
*SSH blocked — REMOTE HOST IDENTIFICATION HAS CHANGED. Expected after Stop → Start*

![Known hosts cleared](docs/screenshots/17_known_hosts_cleared.png)
*ssh-keygen -R clears the old fingerprint — SSH connects cleanly on the next attempt*

![Jenkins service running](docs/screenshots/18_jenkins_service_running.png)
*sudo systemctl status jenkins — active (running). Jenkins came back automatically after reboot.*

The build console showed the cause:

![Pipeline failure console](docs/screenshots/20_pipeline_failure_console.png)
*Console end — `ERROR: script returned exit code -1`, `Finished: FAILURE`*

![Jenkins lost connection exit minus 1](docs/screenshots/21_jenkins_lost_connection_exit_minus1.png)
*Exit code -1 is not a build logic failure — it means Jenkins lost connection to the running Docker process when the server restarted mid-build. The Go compilation was still running when Jenkins went down.*

---

### Challenge: Second Build Attempt — Still Throttled

A second build was triggered, this time to use the Docker layer cache from build #1:

![Rebuild attempt before restructure](docs/screenshots/22_rebuild_attempt_before_restructure.png)
*Decision — attempt a second build before restructuring the architecture, to validate pipeline logic first*

The browser became sluggish almost immediately — the same pattern as before:

![Browser sluggish CPU throttled](docs/screenshots/23_browser_sluggish_cpu_throttled.png)
*Browser struggling to load Jenkins UI — CPU credits draining under Docker build load*

SSH was used to tail the build log directly from disk, bypassing the browser entirely:

```bash
sudo tail -f /var/lib/jenkins/jobs/cloudcommerce-frontend/builds/2/log
```

The build was stuck at the same Go compilation step. Running `top` from SSH:

![SSH top CPU throttled](docs/screenshots/24_ssh_top_cpu_throttled.png)
*top — load average: 17.14 on a 2-core machine. 69.6% wa (disk I/O wait). The server is completely saturated.*

---

### Root Cause Discovered: Jenkins Was Running on t2.micro, Not t3.medium

The `top` output contained the answer:

```
MiB Mem: 957.2 total
```

t3.medium has 4096MB RAM. **957MB is a t2.micro (1GB).** Despite all previous work assuming t3.medium, the `terraform.tfvars` confirmed what was actually provisioned:

```hcl
jenkins_instance_type = "t2.micro"
```

![Top reveals t2 micro](docs/screenshots/25_top_reveals_t2_micro.png)
*top — MiB Mem: 957.2 total. This is 1GB RAM (t2.micro), not 4GB (t3.medium). Every Jenkins crash, throttle, and failed build traced back to this single misconfiguration.*

Every failure throughout Phase 2 had the same root cause: **a 1GB server running Jenkins JVM (~600MB) + Docker build (~400-500MB) = 1100MB needed, 957MB available.** The Go compiler was always killed or throttled before it could finish.

---

### Fix: Instance Resize Directly from AWS Console

Rather than running `terraform apply` — which could trigger another AMI-related instance replacement (Incident 2) — the instance type was changed directly in the AWS Console:

1. EC2 → Instances → Jenkins → Instance State → **Stop** (instance must be fully stopped for the option to appear)
2. Actions → Instance Settings → **Change Instance Type** → `t3.medium`
3. Instance State → **Start**

The `terraform.tfvars` was updated in the local codebase to keep IaC in sync — but no `terraform apply` was run.

![Change instance type console](docs/screenshots/26_change_instance_type_console.png)
*AWS console — Change Instance Type. The option only appears on a fully stopped instance.*

![Instance type changed t3 medium](docs/screenshots/27_instance_type_changed_t3_medium.png)
*Instance type changed to t3.medium — 4GB RAM, confirmed in the AWS console*

![Jenkins t3 medium starting](docs/screenshots/28_jenkins_t3_medium_starting.png)
*Instance starting after resize — Successfully initiated starting*

SSH known hosts cleared again (new hardware after resize), then connected:

![SSH t3 medium connected](docs/screenshots/29_ssh_t3_medium_connected.png)
*SSH to new t3.medium — System information shows Memory usage: 17%. 4GB RAM, only 17% used at idle. Compare to 86% on t2.micro.*

![Jenkins login rebuild](docs/screenshots/30_jenkins_login_rebuild.png)
*Jenkins UI loads instantly — no sluggishness. The browser response difference between t2.micro and t3.medium is immediate.*

| Instance | Total RAM | Jenkins JVM | Available for build | Result |
|---|---|---|---|---|
| t2.micro | 957MB | ~600MB | ~357MB | OOM / CPU throttle / crash |
| t3.medium | 4096MB | ~600MB | ~3400MB | Build completes cleanly |

---

### First Successful Pipeline Build — All 5 Stages Passed

Build #3 was triggered from the Jenkins UI. With 4GB RAM, all 5 stages completed for the first time:

![All 5 stages passed](docs/screenshots/31_all_5_stages_passed.png)
*ALL 5 STAGES PASSED — first successful end-to-end CI pipeline run*

![Pipeline successful overview](docs/screenshots/32_pipeline_successful_overview.png)
*Finished: SUCCESS — duration under 5 minutes with Docker layer cache warm from previous attempts*

**Stage 1 — Checkout:**

![Stage checkout](docs/screenshots/33_stage_checkout.png)
*Checkout — Jenkins cloned `microservices-demo`, checked out commit `e0cacb0c` ("test: trigger pipeline - CloudCommerce test v1")*

**Stage 2 — Build Image:**

![Stage build image](docs/screenshots/34_stage_build_image.png)
*Build Image — Docker build completed in 70 seconds. ECR login succeeded via IAM instance profile. All Docker layers cached from previous attempts — only the final Go compilation (step #13) ran from scratch.*

**Stage 3 — Scan with Trivy:**

![Stage trivy scan](docs/screenshots/35_stage_trivy_scan.png)
*Trivy scan — 5 HIGH vulnerabilities in Go stdlib v1.26.2, 0 CRITICAL. `--exit-code 0` means the scan reports without blocking the build.*

The 5 HIGH vulnerabilities are all in the Go standard library, fixable by upgrading the Dockerfile base image from `golang:1.26.2-alpine` to `golang:1.26.3-alpine`:

| CVE | Issue | Fixed in |
|---|---|---|
| CVE-2026-33811 | DNS CNAME lookup panic | Go 1.26.3 |
| CVE-2026-33814 | HTTP/2 infinite loop | Go 1.26.3 |
| CVE-2026-39820 | Email parser crash | Go 1.26.3 |
| CVE-2026-39836 | NUL byte panic on Windows | Go 1.26.3 |
| CVE-2026-42499 | DoS via phrase parser | Go 1.26.3 |

**Stage 4 — Push to ECR:**

![Stage push to ECR](docs/screenshots/36_stage_push_ecr.png)
*Push to ECR — image `cloudcommerce/frontend:e0cacb0c` pushed successfully. All 18 layers uploaded.*

**Stage 5 — Update values.yaml:**

![Stage update values.yaml](docs/screenshots/37_stage_update_values_yaml.png)
*Update values.yaml — Jenkins cloned `cloudcommerce-devops`, updated `kubernetes/apps/online-boutique/values.yaml` with the new ECR image tag, and committed with `[skip ci]` to prevent an infinite loop.*

---

### The Two Commit IDs — Understanding the Pipeline Audit Trail

The successful build produced two distinct commit IDs:

```
Developer's commit:  e0cacb0c  ← pushed to microservices-demo (app code change)
Jenkins' commit:     977548c   ← pushed to cloudcommerce-devops (values.yaml update)
```

![Two commit IDs explained](docs/screenshots/38_two_commit_ids_explained.png)
*cloudcommerce-devops commit history — Jenkins' commit `977548c` updating values.yaml with image tag `e0cacb0c`. Two repos, two commits, one pipeline.*

| Commit ID | Created by | Repository | Records |
|---|---|---|---|
| `e0cacb0c` | Developer (Dennis4507) | microservices-demo | Application code change |
| `977548c` | Jenkins | cloudcommerce-devops | Image tag `e0cacb0c` written into values.yaml |

The developer's commit ID is used in two places:
1. As the Docker image tag in ECR: `cloudcommerce/frontend:e0cacb0c`
2. Written into `values.yaml` by Jenkins: `tag: "e0cacb0c"`

Jenkins' commit (`977548c`) is what ArgoCD detects — it watches `cloudcommerce-devops`, not `microservices-demo`. When ArgoCD sees `977548c`, it reads the updated `values.yaml`, finds image tag `e0cacb0c`, pulls that image from ECR, and deploys it to k3s.

**The `[skip ci]` tag** prevents an infinite loop: without it, Jenkins would see its own push to `cloudcommerce-devops` as a new event, trigger another build, push again, loop forever.

**Full audit trail for any deployed image:**
```
k3s running:     cloudcommerce/frontend:e0cacb0c
    ↑ deployed by ArgoCD detecting Jenkins commit 977548c in cloudcommerce-devops
        ↑ Jenkins built and pushed image tagged e0cacb0c
            ↑ triggered by developer commit e0cacb0c in microservices-demo
                ↑ "test: trigger pipeline - CloudCommerce test v1" by Dennis4507
```

---

### Progress (Updated)
- [x] Jenkins credentials restored — aws-account-id and github-token under Global scope
- [x] cloudcommerce-frontend pipeline recreated — Pipeline script from SCM, GITScm webhook trigger
- [x] GitHub webhook recreated — push to microservices-demo triggers Jenkins instantly
- [x] Root cause diagnosed — Jenkins was actually running on t2.micro (1GB RAM), not t3.medium
- [x] Instance resized to t3.medium via AWS Console — IaC-safe approach, no terraform apply
- [x] terraform.tfvars updated to t3.medium — IaC kept in sync
- [x] First successful pipeline build — all 5 stages completed cleanly
- [x] Docker image `e0cacb0c` pushed to ECR — `cloudcommerce/frontend:e0cacb0c`
- [x] Trivy scan — 5 HIGH (Go stdlib v1.26.2), 0 CRITICAL, fixable by upgrading to 1.26.3
- [x] values.yaml updated — Jenkins commit `977548c` with `[skip ci]`
- [x] Two commit IDs documented — developer's `e0cacb0c` vs Jenkins' `977548c`
- [ ] Rebuild k3s via Ansible playbook
- [ ] Reinstall ArgoCD
- [ ] Redeploy Online Boutique via ArgoCD
- [ ] Run first full end-to-end pipeline → ECR → ArgoCD → k3s deploy

---

## Phase 4 — Observability *(upcoming)*

- [ ] Deploy Prometheus + Grafana stack
- [ ] Deploy Loki + Promtail for log aggregation
- [ ] Configure AlertManager rules
- [ ] Build Grafana dashboards for cluster and application metrics
- [ ] Monitor HPA scaling events under k6 load

---

## Phase 5 — Security + Load Test *(upcoming)*

- [ ] Integrate Trivy image scanning into Jenkins pipeline
- [ ] Deploy HashiCorp Vault for secrets management
- [ ] Write k6 load test scripts
- [ ] Run load test and observe HPA scaling in real time
- [ ] Document Trivy scan results and k6 performance metrics

---

## Repository Structure

```
cloudcommerce-devops/
├── terraform/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, route tables, internet gateway, security groups
│   │   ├── ec2/          # EC2 instances, Elastic IPs, key pairs, security groups
│   │   ├── ecr/          # 12 container registries with lifecycle policies
│   │   ├── iam/          # Jenkins and k3s roles, ECR policies, instance profiles
│   │   └── dns/          # Route53 hosted zone and records
│   ├── environments/
│   │   ├── dev/          # Development environment (current)
│   │   └── prod/         # Production environment (future)
│   └── keys/             # SSH public key (private key gitignored)
├── ansible/
│   ├── inventory/        # Server IP addresses
│   ├── playbooks/        # Jenkins setup, k3s install, server hardening
│   └── roles/            # Reusable Ansible roles
├── kubernetes/
│   ├── namespaces/       # Namespace definitions
│   ├── apps/
│   │   └── online-boutique/  # Helm values for the 12-service application
│   ├── monitoring/
│   │   ├── prometheus/   # Prometheus config and alerting rules
│   │   └── grafana/      # Dashboard definitions
│   └── argocd/           # ArgoCD application manifests
├── jenkins/
│   ├── Jenkinsfile       # Pipeline definition — build, scan, push, deploy
│   └── casc/             # Jenkins configuration as code
├── scripts/
│   ├── bootstrap.sh      # Prerequisites check + terraform init/plan/apply
│   └── destroy.sh        # Pre-destroy checklist + terraform destroy
└── docs/
    ├── screenshots/      # Evidence for every phase — console, terminal, dashboards
    └── learnings/        # Deep-dive notes on every concept covered in this project
```

---

## How to Deploy

**Prerequisites:**
- AWS account with programmatic access configured (`aws configure --profile cloudcommerce`)
- Terraform >= 1.10.0
- Ansible >= 2.15 (via WSL on Windows)
- kubectl
- Helm >= 3.0

```bash
# 1. Clone this repo
git clone https://github.com/Dennis4507/cloudcommerce-devops.git
cd cloudcommerce-devops

# 2. Generate SSH key pair for EC2 access
ssh-keygen -t rsa -b 4096 -f terraform/keys/cloudcommerce-dev-key

# 3. Provision infrastructure
cd terraform/environments/dev
terraform init
terraform plan
terraform apply

# 4. Configure servers with Ansible
cd ../../../ansible
ansible-playbook playbooks/setup-jenkins.yml
ansible-playbook playbooks/setup-k3s.yml

# 5. Deploy application via ArgoCD
kubectl apply -f kubernetes/argocd/
```

---

## Deep-Dive Learning Notes

Every concept covered in this project — VPC networking, IAM design, Terraform architecture, EC2 and Docker, SSH authentication, AWS CLI, and Git workflow — is documented in detail in [`docs/learnings/`](docs/learnings/). These notes capture not just what was done but why each decision was made, including the tradeoffs considered and the problems encountered.

---

## Author

Built by Denis Muriuki — DevOps and Cloud Engineering Portfolio Project
[GitHub](https://github.com/Dennis4507) · [LinkedIn](https://www.linkedin.com/in/denis-muriuki-693374327/)
