# Terraform Concepts — Deep Dive

## What is Terraform?

Terraform is an Infrastructure as Code (IaC) tool. Instead of clicking through the AWS Console to create servers, networks, and databases, you write code that describes what you want. Terraform reads that code and creates, modifies, or destroys the infrastructure to match.

The core idea: **infrastructure described in code can be version-controlled, reviewed, repeated, and automated.**

## Why IaC Matters

Without IaC (manual approach):
- Click through AWS Console to create a VPC
- Click to create subnets, security groups, EC2 instances
- If you make a mistake, you click to fix it
- Nobody knows what was created or why
- Recreating the environment means repeating every click from memory

With Terraform:
- Write code once describing the desired state
- `terraform apply` creates everything exactly as described
- Changes go through code review before being applied
- Environment can be recreated identically in any region or account
- `terraform destroy` tears everything down cleanly

## The Core Terraform Workflow

```
terraform init    → download providers and connect to backend
terraform plan    → show what will be created/changed/destroyed (dry run)
terraform apply   → actually make the changes
terraform destroy → tear everything down
```

Always run `plan` before `apply`. Read the plan carefully. Only apply when you understand what it will do.

## Providers

A provider is a plugin that connects Terraform to a specific platform. Our AWS provider:

```hcl
provider "aws" {
  region  = var.aws_region
  profile = "cloudcommerce"
}
```

This tells Terraform to talk to AWS, use the Frankfurt region, and authenticate using the `cloudcommerce` CLI profile. Without a provider, Terraform has no idea which platform to talk to.

Terraform downloads providers from the HashiCorp registry during `terraform init`. The version lock file (`.terraform.lock.hcl`) records the exact version downloaded so every team member uses the same one.

## State — Terraform's Memory

Terraform keeps a record of everything it has created called the state file (`terraform.tfstate`). This is how Terraform knows:
- What resources already exist
- What needs to be changed vs created fresh
- What to delete during destroy

Without state, Terraform would try to create everything from scratch every time, even if it already exists.

We store state in S3 (`cloudcommerce-tfstate-927311782753`) instead of locally because:
- Local state is lost if your laptop is stolen or dies
- Team members cannot share local state files
- S3 versioning allows state rollback if it gets corrupted
- S3 native locking prevents two people running `terraform apply` simultaneously and corrupting the state

## Modules vs Environments

This is one of the most important Terraform concepts.

**Module = Blueprint (the HOW)**

A module is a reusable, self-contained piece of infrastructure with one job. It does not know where it will be deployed or for which environment.

```
modules/vpc/      → knows how to build a VPC
modules/iam/      → knows how to build IAM roles
modules/ecr/      → knows how to build ECR repositories
modules/ec2/      → knows how to build EC2 instances
```

**Environment = Deployment (the WHAT and WHERE)**

An environment calls the modules and provides the specific values for that context.

```
environments/dev/   → calls all modules with dev settings (small instances)
environments/prod/  → calls same modules with prod settings (larger instances)
```

Same blueprints, different buildings. Fix a bug in a module once — both environments benefit.

## Variables and tfvars

Variables make code reusable. Instead of hardcoding `"eu-central-1"` in ten files, you define it once and reference it everywhere.

```
variables.tf      → defines variable names, types, and descriptions
terraform.tfvars  → provides the actual values for those variables
```

When Terraform runs, it reads `terraform.tfvars` automatically and fills in all the variable values. This means you can change `k3s_instance_type` from `t3.medium` to `t3.large` in one line without touching any module code.

## Four Files in Every Environment

```
providers.tf     → which cloud provider and how to authenticate
backend.tf       → where to store the state file
variables.tf     → what inputs this environment accepts
terraform.tfvars → the actual values for those inputs
main.tf          → calls all the modules with those values
outputs.tf       → what to print after apply (IPs, URLs, etc.)
```

## for_each — Creating Multiple Resources from a List

Instead of writing 12 identical resource blocks for 12 ECR repositories, we use `for_each`:

```hcl
resource "aws_ecr_repository" "services" {
  for_each = toset(var.services)
  name     = "${var.project}/${each.key}"
}
```

Terraform loops through the list and creates one resource per item. `each.key` becomes the current item in the loop. This is how real infrastructure scales — one block of code, many resources.

## Outputs — Terraform's Results Board

After `terraform apply`, outputs print useful values to the terminal:

```
jenkins_public_ip = "18.184.x.x"
k3s_public_ip     = "3.127.x.x"
ecr_repository_urls = {
  frontend    = "927311782753.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend"
  cartservice = "..."
}
```

Outputs are also how modules share data with each other. The VPC module outputs `vpc_id`, and the EC2 module receives it as an input. No hardcoding — modules are wired together through outputs and variables.

## (known after apply)

In `terraform plan` output you see many values marked `(known after apply)`. This means the value does not exist yet — AWS generates it at creation time (IDs, ARNs, IP addresses). Terraform is saying "I will know this once I create the resource." This is expected and normal.

## The Naming Convention

Every resource we create follows this pattern:
```
${project}-${environment}-resource-type
→ cloudcommerce-dev-vpc
→ cloudcommerce-dev-jenkins-sg
→ cloudcommerce-dev-k3s-role
```

This makes every resource immediately identifiable in the AWS Console — you know the project, the environment, and the purpose at a glance. When you have dozens of resources, this discipline is what keeps things manageable.

## Interview Talking Points

- "I use Terraform modules to separate reusable infrastructure blueprints from environment-specific configuration — the same modules serve both dev and prod with different variable values"
- "State is stored in S3 with versioning and encryption — this enables team collaboration, protects against state loss, and allows rollback if state is corrupted"
- "I use for_each to create multiple similar resources from a list — this avoids repetitive code and makes adding new services as simple as adding a name to a list"
- "I always run terraform plan and read it fully before applying — the plan shows exactly what will change before anything is touched"
- "Terraform's default_tags block automatically applies consistent tags to every resource — this makes cost tracking and resource management clean across the entire project"
