# CloudCommerce DevOps Platform

A production-grade DevOps platform built around a microservices e-commerce application. This project demonstrates end-to-end DevOps engineering — from infrastructure provisioning to CI/CD pipelines, container orchestration, and full-stack observability.

> **Application:** [Google Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) — 12 microservices in Go, Python, Java, C#, and Node.js

---

## Architecture

```
Developer pushes code to GitHub
         │
         ▼ webhook
    ┌─────────────┐
    │   Jenkins   │  ← CI/CD on EC2 t2.micro
    │  Pipeline   │
    │ Build→Scan  │
    │  →Push→     │
    └──────┬──────┘
           │ triggers
           ▼
    ┌─────────────┐         ┌─────────────────┐
    │   ArgoCD    │────────►│  k3s Kubernetes │
    │  (GitOps)   │  sync   │  EC2 t3.medium  │
    └─────────────┘         │                 │
                            │  12 Microservices│
                            │  Prometheus      │
                            │  Grafana         │
                            │  Loki            │
                            └────────┬────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    ▼                ▼                 ▼
              ┌──────────┐   ┌────────────┐   ┌────────────┐
              │ AWS ECR  │   │   AWS S3   │   │  Route53   │
              │ Registry │   │ TF State   │   │    DNS     │
              └──────────┘   └────────────┘   └────────────┘

         All AWS infrastructure provisioned with Terraform
         All server config managed with Ansible
```

---

## Tech Stack

| Category | Tool | Purpose |
|----------|------|---------|
| Cloud | AWS | Primary cloud provider |
| IaC | Terraform | Provision VPC, EC2, ECR, S3, IAM, Route53 |
| Config Mgmt | Ansible | Install k3s, harden servers, manage config |
| Containers | Docker | Multi-stage image builds |
| Orchestration | k3s | Lightweight Kubernetes on EC2 |
| CI/CD | Jenkins | Build, test, scan, and deploy pipeline |
| GitOps | ArgoCD | Kubernetes deployments driven from Git |
| Registry | AWS ECR | Private container image registry |
| Metrics | Prometheus + Grafana | Cluster and application dashboards |
| Logging | Loki + Promtail | Centralised log aggregation |
| Security | Trivy + Vault | Image scanning + secrets management |
| Load Testing | k6 | Simulate high-traffic scenarios |
| Package Mgmt | Helm | Kubernetes application packaging |

---

## Project Phases

- [ ] Phase 1 — Foundation: Terraform infrastructure + Ansible + k3s cluster
  - [x] Repository structure created
  - [x] AWS IAM user group and dedicated project user configured
  - [x] AWS CLI named profile configured (cloudcommerce → eu-central-1)
  - [x] S3 remote state bucket created (versioning + SSE-S3 encryption enabled)
  - [x] Terraform backend, variables, main, and outputs files created
  - [x] VPC module — VPC, subnets, internet gateway, route tables, security groups
  - [x] IAM module — Jenkins and k3s roles, ECR policies, instance profiles
  - [x] ECR module — 12 repositories with lifecycle policies and image scanning
  - [x] EC2 module — Jenkins (t2.micro) and k3s (t3.medium) instances with user data
  - [x] Elastic IPs — static IPs assigned to both servers (survive stop/start)
  - [x] Terraform apply — 45 resources provisioned in AWS (eu-central-1)
  - [x] SSH verified — both servers accessible, Docker 29.5.1 running on both
  - [ ] Ansible — server configuration and k3s install
- [ ] Phase 2 — CI/CD: Jenkins pipeline + ArgoCD GitOps
- [ ] Phase 3 — Kubernetes: Helm deploy + Ingress + HPA + RBAC
- [ ] Phase 4 — Observability: Prometheus + Grafana + Loki + AlertManager
- [ ] Phase 5 — Security + Load Test: Vault + Trivy + k6

---

## Infrastructure Overview

| Resource | Type | Purpose |
|----------|------|---------|
| Jenkins Server | EC2 t2.micro | CI/CD pipeline execution |
| k3s Node | EC2 t3.medium | Kubernetes cluster (all 12 services) |
| ECR | AWS Registry | Stores Docker images |
| S3 Bucket | AWS Storage | Terraform remote state |
| VPC | AWS Network | Isolated network with public/private subnets |
| IAM Roles | AWS Identity | Least-privilege access for EC2 and Jenkins |
| Elastic IPs | AWS Network | Static public IPs — persist across server stop/start |

---

## Repository Structure

```
cloudcommerce-devops/
├── terraform/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, route tables, internet gateway
│   │   ├── ec2/          # EC2 instances, key pairs, security groups
│   │   ├── ecr/          # Container registries for all 12 services
│   │   ├── iam/          # Roles and policies
│   │   └── dns/          # Route53 hosted zone and records
│   └── environments/
│       ├── dev/          # Development environment
│       └── prod/         # Production environment
├── ansible/
│   ├── inventory/        # Server IP addresses
│   ├── playbooks/        # k3s install, Jenkins setup, server hardening
│   └── roles/            # Reusable Ansible roles
├── kubernetes/
│   ├── namespaces/       # Namespace definitions
│   ├── apps/
│   │   └── online-boutique/  # Helm values for the app
│   ├── monitoring/
│   │   ├── prometheus/   # Prometheus config and rules
│   │   └── grafana/      # Dashboard definitions
│   └── argocd/           # ArgoCD application manifests
├── jenkins/
│   ├── Jenkinsfile       # Pipeline definition
│   └── casc/             # Jenkins configuration as code
├── scripts/
│   ├── bootstrap.sh      # Bring infrastructure up
│   └── destroy.sh        # Tear down to save costs
└── docs/
    ├── screenshots/      # Evidence — pipeline runs, dashboards, live app
    └── learnings/        # Deep-dive notes on every concept covered
```

---

## Screenshots

### Phase 1 — Foundation Setup

**GitHub Repository**
![GitHub repo README](docs/screenshots/01-github-repo-readme.png)
*Project repository with full README rendered on GitHub*

**AWS IAM — User Group**
![IAM user group](docs/screenshots/02-iam-user-group.png)
*cloudcommerce-admins group with AdministratorAccess policy attached*

**AWS IAM — Dedicated Project User**
![IAM user](docs/screenshots/03-iam-user.png)
*cloudcommerce-devops IAM user — isolated credentials for this project only*

**AWS S3 — Terraform State Bucket (Versioning)**
![S3 bucket versioning](docs/screenshots/04-s3-tfstate-bucket.png)
*S3 remote state bucket with versioning enabled — allows state rollback if corrupted*

**AWS S3 — Terraform State Bucket (Encryption)**
![S3 bucket encryption](docs/screenshots/04-s3-tfstate-bucket1.png)
*SSE-S3 encryption enabled — state file encrypted at rest in S3*

**Project Structure**
![VS Code project structure](docs/screenshots/05-project-structure.png)
*Full repository structure in VS Code — terraform, ansible, kubernetes, jenkins layers*

**AWS EC2 — Running Instances**
![EC2 instances](docs/screenshots/06-ec2-instances.png)
*Jenkins (t2.micro) and k3s (t3.medium) running in eu-central-1 after terraform apply*

**AWS EC2 — Elastic IPs**
![Elastic IPs](docs/screenshots/07-elastic-ips.png)
*Static IPs assigned to both servers — IPs persist across stop/start cycles*

**AWS VPC**
![VPC](docs/screenshots/08-vpc.png)
*cloudcommerce-dev-vpc with public and private subnets*

**AWS VPC — Subnets**
![VPC subnets](docs/screenshots/09-vpc-subnets.png)
*Public subnet (Jenkins + k3s) and private subnet (future databases)*

**AWS VPC — Private Subnet**
![Private subnet](docs/screenshots/10-vpc-private-subnet.png)
*Private subnet with no route to internet gateway — databases will live here*

**AWS ECR — Repositories**
![ECR repositories](docs/screenshots/11-ecr-repos.png)
*12 container registries — one per microservice, lifecycle policy keeps last 5 images*

**AWS IAM — Roles**
![IAM roles](docs/screenshots/12-iam-roles.png)
*Jenkins role (ECR push+pull) and k3s role (ECR pull-only) — least privilege enforced*

**Terraform Apply — 43 Resources**
![Terraform apply 43](docs/screenshots/13-terraform-apply-43.png)
*Initial apply: 43 resources provisioned including VPC, EC2, ECR, IAM*

**Terraform Apply — Elastic IPs**
![Terraform apply EIP](docs/screenshots/14-terraform-apply-eip.png)
*Second apply: 2 Elastic IPs added without touching existing resources*

**SSH — Server Verified**
![SSH verify](docs/screenshots/15-ssh-verify.png)
*SSH into Jenkins server confirming Ubuntu 22.04 booted correctly*

**Docker — Version**
![Docker version](docs/screenshots/16-docker-version.png)
*Docker 29.5.1 installed via user_data bootstrap script on first boot*

**Docker — Service Status**
![Docker status](docs/screenshots/17-docker-status.png)
*Docker daemon active and running — confirmed via systemctl*

### Phase 2 — CI/CD Pipeline
<!-- screenshot: Jenkins pipeline run showing all green stages -->

### Phase 3 — Kubernetes
<!-- screenshot: ArgoCD UI showing all 12 services synced and healthy -->

### Phase 4 — Observability
<!-- screenshot: Grafana cluster dashboard with real metrics -->

### Phase 5 — Security + Load Test
<!-- screenshot: Trivy scan results and k6 load test -->

---

## How to Deploy

> Full step-by-step instructions added as each phase completes.

**Prerequisites:**
- AWS account with programmatic access
- Terraform >= 1.10.0
- Ansible >= 2.15
- kubectl
- Helm >= 3.0

```bash
# 1. Clone this repo
git clone https://github.com/Dennis4507/cloudcommerce-devops.git
cd cloudcommerce-devops

# 2. Provision infrastructure
cd terraform/environments/dev
terraform init
terraform plan
terraform apply

# 3. Configure servers
cd ../../../ansible
ansible-playbook playbooks/setup-k3s.yml
ansible-playbook playbooks/setup-jenkins.yml

# 4. Deploy application via ArgoCD
kubectl apply -f kubernetes/argocd/
```

---

## What I Learned

### Phase 1 — Foundation

- **AWS IAM design** — least privilege enforced per service: Jenkins gets ECR push+pull (it builds images), k3s gets ECR pull-only (it only runs them); if k3s is compromised, an attacker cannot push malicious images because the permission does not exist on that server
- **IAM roles vs access keys** — EC2 instances use IAM roles, not access keys; roles generate temporary credentials automatically that rotate every few hours, so nothing sensitive ever touches the server disk
- **IAM user groups** — permissions attached to the group, not the individual user; adding a new team member means adding them to the group, not re-configuring every permission
- **AWS CLI named profiles** — isolate credentials per project using `--profile cloudcommerce`; prevents accidental resource creation in the wrong account when managing multiple AWS projects
- **Terraform modules vs environments** — modules are reusable blueprints (the HOW: how to build a VPC); environments are deployments (the WHAT and WHERE: dev vs prod); fix a module once and both environments benefit automatically
- **Terraform remote state** — state stored in S3 with versioning and encryption; versioning allows rollback if state is corrupted; native S3 locking (Terraform 1.10+) prevents two simultaneous `terraform apply` runs from corrupting state
- **VPC networking layers** — route tables control WHERE traffic goes (subnet level); security groups control WHO is allowed through (instance level); both must say yes for a packet to reach its destination
- **Public vs private subnets** — only resources that need internet access live in the public subnet (Jenkins for webhooks, k3s for serving traffic); databases will live in the private subnet with no public route, so even if the app is compromised an attacker cannot reach the database directly
- **ECR lifecycle policies** — automatically delete images older than the last 5 per repository; prevents the registry from accumulating gigabytes of stale images and incurring unnecessary storage costs
- **Credential security** — `.gitignore` blocks secrets before they can be staged; AWS credentials on a public GitHub repo are found by bots within minutes and used to spin up thousands of EC2 instances for cryptocurrency mining
- **Elastic IPs** — standard EC2 instances get a new public IP every time they restart; Elastic IPs are static addresses that stay attached through stop/start cycles, essential for stable SSH access and kubectl configuration
- **Terraform incremental apply** — after the initial apply, adding resources only plans and applies the delta; existing resources are refreshed from state and left completely untouched
- **user_data bootstrap** — EC2 instances run a shell script automatically on first boot; used to install Docker without any manual steps, keeping infrastructure fully code-driven
- **SSH key authentication** — EC2 instances use public/private key pairs instead of passwords; the public key is uploaded to AWS and placed on the server at creation time; the private key stays only on your machine — knowing the IP without the key gets an attacker nothing

> Full deep-dive notes for every concept above are in [`docs/learnings/`](docs/learnings/)

---

## Cost

Infrastructure runs on two EC2 instances (t2.micro + t3.medium) in eu-central-1. Estimated costs:

| State | Cost |
|-------|------|
| Both servers running | ~$0.065/hour (~$1.56/day) |
| Both servers stopped | ~$0.27/day (EBS storage + Elastic IPs) |
| Full project to completion | ~$15-25 total |

Servers are stopped between working sessions using the AWS Console and destroyed after each phase is fully documented using `destroy.sh`.

---

## Author

Built by Denis Muriuki as a hands-on DevOps learning project.  
[GitHub](https://github.com/Dennis4507) · [LinkedIn](https://www.linkedin.com/in/denis-muriuki-693374327/)
