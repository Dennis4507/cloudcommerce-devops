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
  - [ ] VPC module — network foundation
  - [ ] IAM module — roles and instance profiles
  - [ ] ECR module — container registries
  - [ ] Compute module — Jenkins and k3s EC2 instances
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

---

## Repository Structure

```
cloudcommerce-devops/
├── terraform/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, route tables, internet gateway
│   │   ├── compute/      # EC2 instances, key pairs, security groups
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
    └── screenshots/      # Evidence — pipeline runs, dashboards, live app
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
- Terraform >= 1.6
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

### Phase 1 — In Progress
- **AWS IAM best practices** — never use root credentials for daily work; always create dedicated IAM users with least-privilege access; manage permissions at the group level so they scale across multiple users
- **AWS CLI named profiles** — isolate credentials per project using `--profile` flag; prevents accidental resource creation in the wrong account
- **Terraform remote state** — storing state in S3 instead of locally enables team collaboration and prevents state loss; versioning allows rollback; native S3 locking (Terraform 1.10+) prevents concurrent apply conflicts
- **Credential security** — `.gitignore` patterns to block secrets from GitHub; the real-world consequences of leaked AWS keys (bots scan GitHub continuously)

---

## Cost

This project runs on ~$15-30/month on AWS using spot instances and the free tier where possible. A `destroy.sh` script tears down all paid resources when not in use.

---

## Author

Built by Denis Muriuki as a hands-on DevOps learning project.  
[GitHub](https://github.com/Dennis4507) · [LinkedIn](https://www.linkedin.com/in/denis-muriuki-693374327/)
