# EC2, Docker, SSH, and Elastic IPs — Deep Dive

## What is EC2?

EC2 stands for Elastic Compute Cloud. It is AWS's virtual server service. When you create an EC2 instance, AWS allocates a physical server in a data centre and gives you a slice of it — your own virtual machine running Linux (or Windows).

In this project we run two EC2 instances:

```
Jenkins server  → t2.micro  (1 vCPU, 1GB RAM, 20GB disk)  ← CI/CD
k3s node        → t3.medium (2 vCPU, 4GB RAM, 30GB disk)  ← Kubernetes
```

The t2.micro is AWS free-tier eligible. The t3.medium is not — it costs ~$0.052/hour when running.

## AMI — The Operating System Image

When you create an EC2 instance, you choose an AMI (Amazon Machine Image). An AMI is a pre-built snapshot of an operating system — like a USB drive with Linux already installed.

We use Ubuntu 22.04 LTS (Long Term Support) from Canonical (Ubuntu's maker):

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical's AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}
```

The `data` block queries AWS for the latest Ubuntu 22.04 AMI. The `*` at the end is a wildcard — it matches any version, and `most_recent = true` picks the newest one automatically. This means our servers always boot on the latest patched Ubuntu image without us hardcoding a version.

## EBS Volumes — The Server's Hard Drive

Every EC2 instance needs a disk. We use EBS (Elastic Block Store) — AWS's virtual hard drive service.

```hcl
root_block_device {
  volume_size = 20    # GB
  volume_type = "gp3" # General Purpose SSD v3
}
```

`gp3` is the current generation of SSD storage — faster than the older `gp2` and cheaper. We gave Jenkins 20GB (enough for Docker images and builds) and k3s 30GB (more space for 12 running container images).

## user_data — Automating First Boot

`user_data` is a shell script that EC2 runs automatically the first time an instance boots. It runs as root, before any user logs in. We used it to install Docker on both servers:

```bash
#!/bin/bash
apt-get update -y
apt-get install -y ca-certificates curl gnupg
# ... (adds Docker's official apt repository)
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker
systemctl start docker
```

`systemctl enable docker` means Docker starts automatically every time the server reboots — not just the first time.

This is why Docker was already installed and running when we SSH'd in. We never touched the server manually. The infrastructure bootstrapped itself.

## Why Docker on Both Servers

| Server | Why Docker |
|--------|-----------|
| Jenkins | Builds Docker images from source code, then pushes them to ECR |
| k3s | k3s uses containerd (a component of Docker) as its container runtime — every Kubernetes pod runs inside a container |

Without Docker on Jenkins, it cannot build images. Without a container runtime on k3s, Kubernetes has no way to actually run containers.

## SSH Key Authentication

EC2 instances do not use passwords. They use SSH key pairs — a mathematically linked pair of files:

```
Private key  → stays on your machine (never shared, never leaves)
Public key   → uploaded to AWS, placed on the server at creation
```

How it works:
```
You run: ssh -i private-key ubuntu@server-ip
        ↓
Your machine sends a challenge to the server
        ↓
Server checks: does this private key match the public key we have?
        ↓
Yes → you're in. No → Permission denied.
```

In Terraform, we created a key pair from our generated public key:
```hcl
resource "aws_key_pair" "main" {
  key_name   = var.key_pair_name
  public_key = file("${path.module}/../../keys/${var.key_pair_name}.pub")
}
```

Terraform uploaded the public key to AWS. Both EC2 instances were created with that key pair attached. The private key (`cloudcommerce-dev-key`) stays in `terraform/keys/` and is gitignored — it never leaves your machine.

**Why SSH keys over passwords:**
- Passwords can be brute-forced. A 4096-bit RSA key cannot.
- Passwords can be leaked. A key sitting on your disk is only exposed if your machine is compromised.
- You can revoke a key pair in AWS without touching the server.

## Elastic IPs — Static Public Addresses

By default, EC2 instances get a dynamic public IP. Every time you stop and start the instance, AWS assigns a different IP. This breaks everything that depends on a fixed address — SSH commands, Ansible inventory, kubectl config.

Elastic IPs solve this. An Elastic IP is a static public IP address you own. AWS assigns it to your instance and it stays attached through stop/start cycles.

```hcl
resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"
}
```

**Cost model:**
- Elastic IP while instance is **running** → free
- Elastic IP while instance is **stopped** → ~$0.005/hour (~$3.60/month)

This is intentional — AWS charges for idle IPs to discourage hoarding addresses that aren't in use.

Our permanent IPs:
```
Jenkins: 3.127.90.169
k3s:     63.184.235.88
```

These IPs will not change when we stop and start the servers between sessions.

## The Stop/Start Workflow

Because we have Elastic IPs, our working pattern is:

```
Start of session:
  AWS Console → EC2 → Instances → Select both → Start
  (servers are ready in ~30 seconds)

End of session:
  AWS Console → EC2 → Instances → Select both → Stop
  (compute billing stops immediately)
```

Cost while stopped: ~$0.27/day (EBS disks + idle Elastic IPs)
Cost while running: ~$0.065/hour

Ansible configuration, k3s, Jenkins — everything installed on the servers persists on the EBS disk. You do not reinstall anything between sessions.

## Verifying a Server After Boot

After SSH'ing in, we always verify the key components:

```bash
docker --version              # confirms Docker installed correctly
sudo systemctl status docker  # confirms Docker daemon is running
```

`systemctl` is the Linux service manager. `status` shows whether a service is active, inactive, or failed. `active (running)` means the daemon started successfully and is healthy.

The `--no-pager` flag prevents output from going into an interactive scrolling view:
```bash
sudo systemctl status docker --no-pager
```

## Interview Talking Points

- "EC2 instances are bootstrapped with user_data scripts — Docker is installed automatically on first boot without any manual steps, keeping the infrastructure fully code-driven"
- "We use SSH key pairs instead of passwords — the private key never leaves the engineer's machine, and access can be revoked by removing the key pair from AWS"
- "Elastic IPs give our servers permanent public addresses — this is essential when you have Ansible inventory files, kubeconfig, and SSH configs all referencing a specific IP"
- "Servers are stopped between sessions, not destroyed — once Ansible has configured them, we preserve the disk state; only compute billing stops when the instance is stopped"
- "We chose t3.medium for k3s because it needs 4GB RAM to run 12 microservices comfortably — t2.micro (1GB) would cause out-of-memory kills under load"
