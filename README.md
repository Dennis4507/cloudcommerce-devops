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
    │   Jenkins   │  ← CI/CD on EC2 t2.micro (eu-central-1)
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

- [ ] Install Jenkins via Ansible
- [ ] Configure Jenkins (plugins, credentials, pipeline)
- [ ] Write Jenkinsfile — build, scan with Trivy, push to ECR
- [ ] Configure GitHub webhook → Jenkins trigger
- [ ] Set up ArgoCD for GitOps deployment

---

## Phase 3 — Kubernetes *(upcoming)*

- [ ] Install k3s via Ansible
- [ ] Configure kubectl on local machine
- [ ] Deploy Online Boutique via Helm
- [ ] Configure Ingress
- [ ] Set up HPA (Horizontal Pod Autoscaler)
- [ ] Configure RBAC

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
