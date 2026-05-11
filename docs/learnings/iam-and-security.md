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

## Interview Talking Points

- "I use IAM roles for EC2 instances rather than access keys — roles provide temporary credentials that rotate automatically, eliminating the risk of long-lived credentials being stolen from the server"
- "I follow least privilege — Jenkins has write access to ECR because it builds and pushes images, but k3s only has read access because it only runs images"
- "I use IAM user groups so permissions are managed at the group level, not per user — this scales cleanly when the team grows"
- "Credentials should never appear outside a terminal prompt — exposed credentials in any text format must be rotated immediately"
