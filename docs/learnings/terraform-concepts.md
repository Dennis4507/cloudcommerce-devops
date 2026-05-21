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

We store state in S3 (`cloudcommerce-tfstate-<your-account-id>`) instead of locally because:
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
  frontend    = "<your-account-id>.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend"
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

## Reading the Terraform Plan — The Most Important Habit

Every `terraform plan` output uses symbols to tell you what will happen to each resource. Reading these carefully before typing `yes` is the most important habit in Terraform.

```
+    create          → new resource, nothing destroyed. Generally safe.
~    update          → change existing resource in-place. Generally safe.
-    destroy         → resource will be deleted. Stop and understand why.
-/+  destroy/create  → resource must be destroyed and recreated. STOP. Read everything.
```

The `-/+` symbol is the dangerous one. It means the change cannot be made to the existing resource — Terraform must delete it and build a new one. For an EC2 instance, this means:

- The old server is terminated
- All installed software is gone
- A fresh blank server is created in its place
- Everything must be reinstalled

**Always look for `-/+` before typing `yes`.** If you see it on an EC2 instance, database, or any stateful resource — stop, understand why it is happening, and decide if that is truly what you want.

## The AMI Data Source Pitfall — A Real Incident

**What is an AMI?**

An AMI (Amazon Machine Image) is the template used to create an EC2 instance — think of it as the operating system installer. AWS regularly publishes new AMIs when Ubuntu releases security patches.

**The pitfall:**

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true   ← always fetches the newest AMI from AWS
  ...
}
```

`most_recent = true` means every time Terraform runs, it checks for the newest Ubuntu AMI. If AWS has published a new one since your servers were created, Terraform sees a mismatch:

```
~ ami = "ami-0f7804991cb8f07c4" -> "ami-0c905937c14bd22b0" # forces replacement
```

Because EC2 instances cannot change their AMI after creation, Terraform marks the instance as `-/+` — destroy and recreate. If you approve the plan without noticing this line, **both servers are destroyed and rebuilt from scratch**.

**This happened in this project.** Both the Jenkins and k3s servers were destroyed because a new Ubuntu AMI was published between initial setup and a later `terraform apply`. Everything installed on both servers was lost.

**The fix — `lifecycle { ignore_changes = [ami] }`:**

```hcl
resource "aws_instance" "jenkins" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.jenkins_instance_type

  lifecycle {
    ignore_changes = [ami]   ← Terraform will never recreate this instance due to an AMI change
  }
}
```

The `lifecycle` block tells Terraform: "even if the desired state differs from reality on these specific attributes, do not touch them." The AMI data source still runs and finds the latest image — but Terraform ignores the difference on existing instances. New instances created in the future will use the latest AMI; existing instances are left alone.

This is the correct approach for long-lived servers managed with Ansible. AMI updates on running servers are handled through configuration management, not by destroying and rebuilding.

## Infrastructure as Code — Why Incidents Are Recoverable

The Terraform AMI incident destroyed both servers. Every piece of installed software — Jenkins, all plugins, all credentials, all configuration, k3s, ArgoCD, the entire Online Boutique deployment — was gone.

Recovery took a few hours, not days. Because everything was in code.

**Without IaC (the old way):**
```
Server destroyed
  → Remember what was installed (can you remember every step from 3 weeks ago?)
  → Click through AWS console to rebuild
  → SSH in and run commands from memory
  → Re-enter all configuration by hand
  → Hope nothing is missed
  → Days of work, inconsistent result
```

**With IaC (how we recovered):**
```
Server destroyed
  → ansible-playbook setup-jenkins.yml   ← Jenkins back, identical to before
  → ansible-playbook setup-k3s.yml       ← k3s back, identical to before
  → ansible-playbook setup-argocd.yml    ← ArgoCD back, identical to before
  → kubectl apply -f kubernetes/argocd/  ← Online Boutique redeployed from Git
  → Hours of work, identical result
```

The servers are disposable. The code is permanent. **This is the entire point of Infrastructure as Code.**

In professional environments, servers are treated as "cattle not pets" — they are not hand-crafted and maintained lovingly. They are created from code, used, and replaced when needed. No server is irreplaceable when the code that defines it is version-controlled.

## lifecycle — Controlling How Terraform Manages Changes

The `lifecycle` block gives you fine-grained control over how Terraform handles a resource:

```hcl
lifecycle {
  ignore_changes = [ami]            # ignore changes to this specific attribute
  prevent_destroy = true            # refuse to destroy this resource (use for databases)
  create_before_destroy = true      # create the new resource before destroying the old one
}
```

**`ignore_changes`** — the most commonly used. Tells Terraform to ignore drift on specific attributes. Useful when:
- External systems modify attributes after creation (like AWS auto-assigning IPs)
- You want to manage some attributes outside of Terraform (like AMI updates via Ansible)

**`prevent_destroy`** — adds a safety net on critical resources:
```hcl
resource "aws_db_instance" "main" {
  lifecycle {
    prevent_destroy = true   # terraform destroy will fail with an error rather than delete the database
  }
}
```
Use this on databases, S3 buckets with data, and anything that cannot be easily recreated.

**`create_before_destroy`** — for zero-downtime replacements. Terraform creates the new resource, updates all references to point at it, then destroys the old one. Without this, the old resource is destroyed first, creating a window of downtime.

## terraform plan vs terraform apply — The Two-Step Rule

**Always run `terraform plan` first and read it fully.** `terraform apply` shows you the same plan and asks for confirmation — but by the time you see the plan in `apply`, you are one keystroke away from making changes.

The professional workflow:

```bash
terraform plan -out=tfplan    # save the plan to a file
# read the output carefully
# look for -/+ symbols
# understand every change
terraform apply tfplan         # apply exactly the saved plan, no surprises
```

Using `-out=tfplan` means the apply uses the exact plan you reviewed — not a new plan generated at apply time (which could differ if something changed between plan and apply).

**Questions to ask before typing `yes`:**

1. Are there any `-/+` resources? If yes — what are they and why?
2. Are there any `-` (destroy only) resources? If yes — is that intended?
3. Does the number of resources being created/changed/destroyed match what I expect?
4. Are any resources I care about being replaced that I did not expect?

Thirty seconds reading the plan can save hours of recovery work.

## Interview Talking Points

- "I use Terraform modules to separate reusable infrastructure blueprints from environment-specific configuration — the same modules serve both dev and prod with different variable values"
- "State is stored in S3 with versioning and encryption — this enables team collaboration, protects against state loss, and allows rollback if state is corrupted"
- "I use for_each to create multiple similar resources from a list — this avoids repetitive code and makes adding new services as simple as adding a name to a list"
- "I always run terraform plan and read it fully before applying — specifically looking for -/+ symbols which indicate a resource must be destroyed and recreated"
- "I learned this the hard way — a terraform apply destroyed both EC2 servers because a new Ubuntu AMI was published and our data source used most_recent = true. The fix was lifecycle { ignore_changes = [ami] }. Recovery took a few hours because every installation step was in Ansible playbooks"
- "Infrastructure as Code means servers are disposable — when ours were accidentally destroyed, we rebuilt everything identically in hours using the same playbooks that created it originally. That is the entire point of IaC"
- "I use lifecycle prevent_destroy on any resource that cannot be easily recreated — databases, S3 buckets with data, anything stateful"
