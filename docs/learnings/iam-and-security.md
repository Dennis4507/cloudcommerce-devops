# IAM and Security — Deep Dive

## What is IAM?

IAM stands for Identity and Access Management. It is AWS's system for controlling who can do what. Every action in AWS — creating a server, pushing an image, reading a file — requires permission. IAM is where those permissions are defined and assigned.

The core principle behind IAM is **least privilege**: every identity gets exactly the permissions it needs for its job, and nothing more.

## The Four IAM Building Blocks

### 1. IAM User
A human identity with long-term credentials (access key + secret key). Used by people or applications that need to interact with AWS from outside — like your `cloudcommerce-devops` user that Terraform uses.

### 2. IAM Role
An identity that AWS services can assume temporarily. Unlike users, roles have no permanent credentials — they generate temporary tokens automatically. EC2 instances, Lambda functions, and other services use roles.

### 3. IAM Policy
A JSON document listing what actions are allowed or denied. Policies are attached to users or roles. Without a policy, a role has zero permissions.

### 4. IAM Instance Profile
A container that wraps a role so EC2 instances can use it. EC2 cannot directly assume a role — it needs an instance profile as the intermediary. When EC2 boots, it reads its instance profile, assumes the role, and gets the permissions automatically.

## Why EC2 Servers Need IAM Roles

By default, an EC2 instance has zero AWS permissions. It cannot touch ECR, S3, or any other service. If Jenkins needs to push a Docker image to ECR, it must have permission. Instead of putting credentials on the server (dangerous — if the server is compromised, credentials are stolen), we attach an IAM role. The server inherits permissions securely without storing any credentials on disk.

## Our IAM Design

```
Jenkins Role
  └── Jenkins ECR Policy
        ├── ecr:GetAuthorizationToken    (authenticate to ECR)
        ├── ecr:PutImage                 (push built images)
        ├── ecr:InitiateLayerUpload      (upload image layers)
        ├── ecr:UploadLayerPart          (upload image layers)
        ├── ecr:CompleteLayerUpload      (finalise upload)
        ├── ecr:BatchGetImage            (pull images)
        ├── ecr:GetDownloadUrlForLayer   (pull image layers)
        ├── ecr:DescribeRepositories     (list repos)
        └── ecr:ListImages               (list images)

k3s Role
  └── k3s ECR Policy
        ├── ecr:GetAuthorizationToken    (authenticate to ECR)
        ├── ecr:BatchGetImage            (pull images to run)
        ├── ecr:GetDownloadUrlForLayer   (pull image layers)
        ├── ecr:DescribeRepositories     (list repos)
        └── ecr:ListImages               (list images)
```

Jenkins can push and pull — it builds and deploys.
k3s can only pull — it runs images, never builds them.

If the k3s node is ever compromised, an attacker cannot push malicious images to ECR. The permission simply does not exist on that server.

## Credentials Security — Lessons Learned

During setup we learned several hard lessons about credential security:

**Never paste credentials in chat, email, or any text outside the terminal.** Credentials exposed in any communication channel must be rotated immediately — bots scrape chat logs, emails, and files continuously.

**Never commit credentials to Git.** AWS credentials on a public GitHub repo are found by automated bots within minutes. The bots spin up thousands of EC2 instances for cryptocurrency mining, running up bills of thousands of dollars before you notice.

**Use named AWS CLI profiles.** Instead of a default profile that applies to everything, we use `--profile cloudcommerce` for all commands in this project. This isolates credentials per project and prevents accidentally creating resources in the wrong account.

**Use IAM roles for servers, not access keys.** Access keys on a server are a liability — they can be stolen. IAM roles generate temporary credentials automatically and rotate them transparently. No credentials on disk.

**The .gitignore is your first line of defence:**
```
*.pem           # SSH private keys
*.key           # private keys
*.csv           # credential export files
*accessKeys*    # AWS access key files
.env            # environment variable files with secrets
```

## The Difference Between Root and IAM Users

```
Root user  → the master key to your AWS account
             Only use for: billing, account recovery, closing the account
             Never use for: daily work, Terraform, CLI commands

IAM user   → a specific identity with specific permissions
             Use for: everything else
```

We created a dedicated `cloudcommerce-devops` IAM user for this project. If that user's credentials are compromised, we delete and recreate them. Root credentials cannot be rotated the same way.

## IAM User Groups

We put the `cloudcommerce-devops` user in the `cloudcommerce-admins` group rather than attaching permissions directly to the user. This is the scalable pattern:

```
Group: cloudcommerce-admins  ← permissions attached here
  └── User: cloudcommerce-devops
  └── User: (future team member)
  └── User: (CI/CD service account)
```

Change permissions once on the group → all members inherit the change automatically. No need to update each user individually.

## Key Rotation — The Safe Way to Replace Credentials

When credentials are compromised or need updating, never just delete them immediately — other systems may still be using them. The safe process:

1. Create a new access key
2. Update all systems using the old key with the new key
3. Test everything works with the new key
4. Deactivate the old key
5. Wait and confirm nothing breaks
6. Delete the old key

This is called key rotation and is standard security practice in every organisation.

## ECR as a Private Registry — A Security Decision

All Docker images for this project are stored in AWS ECR (Elastic Container Registry) — a private registry. This is a deliberate security decision.

**What this means:**
- Nobody can pull our images without AWS credentials
- No images are on public Docker Hub where anyone can inspect them
- Access is controlled by IAM — only the Jenkins role (push) and k3s role (pull) have permission
- ECR automatically scans images for vulnerabilities on push

**Why not Docker Hub?**
Docker Hub public repositories expose your images — anyone can pull and inspect them, including your application code, configurations, and base image versions. A private registry keeps your supply chain internal.

## Trivy — Reporting vs Blocking

Trivy scans Docker images for known CVEs (Common Vulnerabilities and Exposures) before they are pushed to ECR. There are two modes:

```bash
--exit-code 0    # report vulnerabilities but always pass — build continues
--exit-code 1    # fail the build if HIGH or CRITICAL vulnerabilities found
```

This project uses `--exit-code 0` — vulnerabilities are reported in the build log but do not stop the pipeline.

**Why `--exit-code 0` initially:**
- Establishes a baseline — see what vulnerabilities exist before deciding on thresholds
- Avoids blocking all deployments while investigating findings
- Gives time to understand which CVEs are exploitable vs theoretical

**What `--exit-code 1` does in production:**
- Any HIGH or CRITICAL CVE fails the build — the image never reaches ECR
- Forces the team to fix or explicitly accept each vulnerability before shipping
- Creates a hard security gate in the pipeline

The migration from `--exit-code 0` to `--exit-code 1` is a planned improvement once a vulnerability baseline is established.

## Real Credential Exposure — The GitHub Token Incident

During setup, a GitHub Personal Access Token was accidentally pasted in a chat message. The token was visible in plain text.

**Immediate response:**
1. Identified the exposure immediately
2. Revoked the token in GitHub Settings → Developer settings → Personal access tokens
3. Generated a new token
4. Updated the Jenkins credentials store with the new token
5. Updated `secrets-and-ips.txt` locally

**Why this matters:** Automated bots scan chat platforms, GitHub commits, Pastebin, and similar services continuously looking for credentials. A token exposed in any text format can be picked up and used within minutes — even if you delete the message immediately.

**The rule applied from this point forward:** Credentials are typed only into:
- Terminal prompts (SSH, AWS CLI configuration)
- Secret manager UIs (Jenkins Credentials Store, AWS Secrets Manager)
- Encrypted local files (gitignored)

They are never pasted into chat, email, documentation, or any text visible to anyone else.

## Jenkins Security Gaps — Known and Accepted for Portfolio

Jenkins in this project runs with two known security gaps that are acceptable for a portfolio environment but would be addressed in production:

**1 — HTTP not HTTPS**

Jenkins UI is served on `http://3.127.90.169:8080` — plain HTTP, no TLS. This means:
- Credentials entered in the browser could be intercepted on the network
- The Jenkins API is unencrypted

In production: put Jenkins behind an HTTPS reverse proxy (nginx or AWS ALB with ACM certificate). For this portfolio project the server is accessed only by you over a known network.

**2 — Docker credentials stored unencrypted**

When Jenkins authenticates to ECR via `docker login`, Docker stores the temporary token in `/var/lib/jenkins/.docker/config.json` in plain text. Jenkins warns about this:

```
WARNING! Your credentials are stored unencrypted in '/var/lib/jenkins/.docker/config.json'
```

The token is temporary (expires in 12 hours) and the file is on a server only accessible via SSH. The risk is low. In production: configure `docker-credential-ecr-login` as a credential helper — it handles ECR tokens in memory and never writes them to disk.

## Security Groups — Network-Level Access Control

Security groups act as firewalls for EC2 instances. Only specific ports are open:

```
Jenkins server (3.127.90.169)
  ├── Port 22  — SSH (your IP only)
  ├── Port 8080 — Jenkins UI (open to internet for webhook delivery)
  └── All other ports — BLOCKED

k3s server (63.184.235.88)
  ├── Port 22   — SSH (your IP only)
  ├── Port 80   — Online Boutique HTTP (open to internet)
  ├── Port 6443 — kubectl API (your IP only)
  ├── Port 30080 — ArgoCD UI (your IP only)
  └── All other ports — BLOCKED
```

This is defence in depth — even if an attacker knows the server IP, they can only reach services that are explicitly allowed. The kubectl API and ArgoCD UI are restricted to your IP only — they are never exposed to the public internet.

## Security Practices Summary — What Was Done and Why

| Practice | Where Applied | Why |
|---|---|---|
| IAM roles for EC2 | Jenkins and k3s | No credentials on disk |
| Least privilege | IAM policies | Jenkins can push, k3s can only pull |
| Private ECR registry | All images | Images not publicly accessible |
| Jenkins Credentials Store | Pipeline secrets | Secrets masked in logs, never in code |
| .gitignore for secrets | SSH keys, state files | Prevents accidental credential commits |
| Trivy image scanning | Every build | Catch CVEs before they reach production |
| Security groups | Both EC2 instances | Network-level access control |
| Named AWS profiles | Terraform/CLI | Prevent wrong-account operations |
| Dedicated IAM user | cloudcommerce-devops | Isolate project credentials |
| Credential rotation | GitHub token incident | Immediate response to exposure |
| [skip ci] in commits | Jenkins → GitHub | Prevent pipeline credential loops |

## Interview Talking Points

- "I use IAM roles for EC2 instances rather than access keys — roles provide temporary credentials that rotate automatically, eliminating the risk of long-lived credentials being stolen from the server"
- "I follow least privilege — Jenkins has write access to ECR because it builds and pushes images, but k3s only has read access because it only runs images"
- "I use IAM user groups so permissions are managed at the group level, not per user — this scales cleanly when the team grows"
- "Credentials should never appear outside a terminal prompt — we had a real token exposure incident during this project and rotated it immediately. That experience reinforced why credentials belong only in secret managers, never in chat or documentation"
- "Trivy scans every image before it reaches ECR. Currently using --exit-code 0 to establish a vulnerability baseline — the next step is switching to --exit-code 1 to create a hard security gate that blocks HIGH and CRITICAL CVEs from being pushed"
- "Jenkins has known security gaps in this setup — HTTP instead of HTTPS, and unencrypted Docker credentials. Both are documented, understood, and acceptable for a portfolio environment. In production I would add an HTTPS reverse proxy and configure docker-credential-ecr-login"
- "Security groups restrict each server to only the ports it needs — the kubectl API and ArgoCD UI are restricted to my IP only and never exposed to the public internet"
