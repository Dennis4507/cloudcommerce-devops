# Jenkins and CI/CD — Deep Dive

## What is CI/CD?

CI/CD stands for Continuous Integration and Continuous Delivery (or Deployment). It is the practice of automating every step between a developer pushing code and that code running in production.

**Without CI/CD:**
```
Developer pushes code
→ Someone manually builds a Docker image
→ Someone manually tests it
→ Someone manually scans it for vulnerabilities
→ Someone manually pushes it to the registry
→ Someone manually updates the server
→ Hope nothing breaks
```

**With CI/CD:**
```
Developer pushes code
→ Pipeline triggered automatically
→ Image built automatically
→ Tests run automatically
→ Security scan runs automatically
→ Image pushed automatically
→ Deployment triggered automatically
→ All within minutes, every time, consistently
```

The pipeline is defined in code (a `Jenkinsfile`) — it lives in the same repository as the application, is reviewed with the same discipline as application code, and is versioned alongside it.

### Continuous Integration (CI)
The practice of frequently merging code into a shared branch and automatically verifying it. Every push triggers a build. If the build or tests fail, the team knows immediately — not three weeks later when the release is due.

### Continuous Delivery (CD)
The practice of keeping software always in a releasable state. Every successful CI run produces an artifact (in our case, a Docker image) that could be deployed at any time.

### Continuous Deployment
Every successful pipeline run automatically deploys to production without human approval. We use this pattern via ArgoCD — once Jenkins builds and pushes a verified image, ArgoCD detects the change and deploys automatically.

## What is Jenkins?

Jenkins is a self-hosted, open-source automation server. It orchestrates CI/CD pipelines — listening for triggers (GitHub webhook, schedule, manual), running jobs, and reporting results.

Jenkins runs as a server (on our EC2 t3.medium — 4GB RAM) and exposes a web UI at port 8080. Pipelines are defined in a `Jenkinsfile` — a Groovy-based DSL that sits in the repository root.

**Why Jenkins over managed alternatives (GitHub Actions, CircleCI)?**
- Jenkins runs on your infrastructure — no per-minute billing for compute
- Full control over the runtime environment
- Deep plugin ecosystem (1800+ plugins)
- Standard in enterprise environments — appearing on job descriptions
- The Jenkinsfile documents the pipeline as code in the same repo as the application

## Jenkins Architecture

```
Jenkins Controller (our EC2 t2.micro)
    │  manages and schedules jobs
    │
    ├── Build Agent 1  ← where actual build commands run
    ├── Build Agent 2
    └── ...
```

In a production setup, the controller delegates build work to agents — separate machines that run the actual pipeline steps. For this project, builds run on the controller itself (no separate agents needed at this scale).

## Java Runtime Requirement

Jenkins is a Java application. The Jenkins controller must run on a compatible JVM.

**Current requirement (as of 2025–2026):** Java 21 minimum. Java 25 is also supported.

This is a breaking change from older Jenkins versions which ran on Java 11 or Java 17. If Jenkins is installed with Java 17 and then upgraded, the service will fail to start with:

```
Running with Java 17 from /usr/lib/jvm/java-17-openjdk-amd64, which is older than
the minimum required version (Java 21).
Supported Java versions are: [21, 25]
```

Jenkins does not refuse installation on the wrong Java version — it only rejects it at startup. This is a silent trap: the package installs cleanly, but the service refuses to start.

**Installing the correct Java:**
```bash
apt install openjdk-21-jdk
```

If Java 17 was previously installed, remove it to reclaim ~200MB of disk space:
```bash
apt remove openjdk-17-jdk
apt install openjdk-21-jdk
```

## Installing Jenkins via Ansible

Jenkins installation via Ansible involves four distinct steps:

1. **Install Java 21** — the runtime Jenkins needs
2. **Import the GPG signing key** — so apt can verify Jenkins packages are authentic
3. **Add the Jenkins apt repository** — so apt knows where to find Jenkins packages
4. **Install and start Jenkins** — the actual package installation and service startup

Each step must succeed in sequence. A failure at step 2 or 3 means step 4 will fail with a `NO_PUBKEY` error even though the problem is not in step 4.

See `docs/learnings/linux-package-management.md` for the GPG key challenges encountered during this installation.

## The Initial Admin Password

On first startup, Jenkins generates a random password to protect the setup wizard:

```
/var/lib/jenkins/secrets/initialAdminPassword
```

This password is required to unlock the Jenkins UI for the first time. It can be retrieved with:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

In our Ansible playbook, this is automated:

```yaml
- name: Get Jenkins initial admin password
  command: cat /var/lib/jenkins/secrets/initialAdminPassword
  register: jenkins_password
  changed_when: false

- name: Print Jenkins initial admin password
  debug:
    msg: "Jenkins initial admin password: {{ jenkins_password.stdout }}"
```

The password is printed at the end of the Ansible run. Once you log in and create an admin account, the initial password is no longer valid.

## Plugin Ecosystem

Jenkins is a framework. Almost all functionality comes from plugins — there are over 1,800 available. At initial setup, Jenkins offers two choices:

**Install suggested plugins** — Jenkins recommends a curated set covering the most common needs:
- Git / GitHub integration
- Pipeline (the `Jenkinsfile` DSL)
- Credentials (secure secret storage)
- Workspace management
- Matrix Authorization, Mailer, and other core utilities

**Select plugins to install** — choose manually from the full list.

For initial setup, suggested plugins is the correct choice. Selecting manually risks missing transitive dependencies and produces a half-configured Jenkins with cryptic errors when you try to build pipelines. Additional plugins can always be added later.

**Docker Pipeline is NOT included in suggested plugins.** This was discovered during reinstallation — the suggested set does not include Docker Pipeline, which is required for any Jenkinsfile that builds Docker images. It must be installed separately after initial setup:

```
Manage Jenkins → Plugins → Available plugins → search "Docker Pipeline" → Install
```

Without Docker Pipeline, any `docker.build()` or `docker.withRegistry()` call in a Jenkinsfile will fail with an unrecognised step error.

## Jenkins Credentials Store

Jenkins has a built-in secrets manager called the Credentials Store. This is where sensitive values live — AWS credentials, GitHub tokens, Docker registry passwords — so they never appear in Jenkinsfiles or logs.

Credentials are referenced in a Jenkinsfile by ID:
```groovy
withCredentials([string(credentialsId: 'aws-account-id', variable: 'AWS_ACCOUNT_ID')]) {
    sh "docker push ${AWS_ACCOUNT_ID}.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend"
}
```

The actual value is injected at runtime and masked in logs. This is how CI/CD pipelines handle secrets without hardcoding them.

## Debugging Jenkins Service Failures

When Jenkins fails to start, the diagnostic sequence:

**Step 1: systemctl status**
```bash
sudo systemctl status jenkins.service --no-pager
```
Shows the last few log lines and the exit code.

**Step 2: journalctl**
```bash
sudo journalctl -xeu jenkins.service --no-pager | tail -50
```
Shows the full service log. Often still only shows "process exited with error code" without a root cause.

**Step 3: Run the binary directly**
```bash
sudo /usr/bin/jenkins
```
Bypasses systemd entirely and shows Jenkins' actual startup output. This is where the real error appears — Java version errors, port conflicts, permission issues.

## Jenkins and Docker

Jenkins builds Docker images as part of the CI pipeline. For Jenkins to run Docker commands, the jenkins system user must be a member of the docker group:

```bash
usermod -aG docker jenkins
```

In Ansible:
```yaml
- name: Add jenkins user to docker group
  user:
    name: jenkins
    groups: docker
    append: yes      # append to existing groups, don't replace them
```

Without this, any Docker command in a Jenkinsfile (`docker build`, `docker push`) will fail with `permission denied while trying to connect to the Docker daemon socket`.

## The Jenkinsfile — Complete Pipeline

A Jenkinsfile defines the pipeline as code. It lives in the root of the application repository and is written in Groovy DSL. This is the complete pipeline built for this project:

```groovy
pipeline {
    agent any

    environment {
        AWS_REGION = 'eu-central-1'
        SERVICE    = 'frontend'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm   // clones the repo Jenkins was triggered from
            }
        }

        stage('Build Image') {
            steps {
                withCredentials([string(credentialsId: 'aws-account-id', variable: 'AWS_ACCOUNT_ID')]) {
                    script {
                        env.IMAGE_TAG    = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                        env.ECR_REGISTRY = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                        env.ECR_IMAGE    = "${env.ECR_REGISTRY}/cloudcommerce/${SERVICE}:${env.IMAGE_TAG}"
                    }
                    sh '''
                        aws ecr get-login-password --region ${AWS_REGION} \
                            | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                        docker build -t ${ECR_IMAGE} src/${SERVICE}/
                    '''
                }
            }
        }

        stage('Scan with Trivy') {
            steps {
                sh '''
                    trivy image \
                        --exit-code 0 \
                        --severity HIGH,CRITICAL \
                        --no-progress \
                        ${ECR_IMAGE}
                '''
            }
        }

        stage('Push to ECR') {
            steps {
                sh 'docker push ${ECR_IMAGE}'
            }
        }

        stage('Update values.yaml') {
            steps {
                withCredentials([
                    string(credentialsId: 'aws-account-id', variable: 'AWS_ACCOUNT_ID'),
                    usernamePassword(credentialsId: 'github-token', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')
                ]) {
                    sh '''
                        git config user.email "jenkins@cloudcommerce.dev"
                        git config user.name "Jenkins"

                        NEW_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/cloudcommerce"
                        sed -i "s|  repository:.*|  repository: ${NEW_REPO}|" kubernetes/apps/online-boutique/values.yaml
                        sed -i "s|  tag:.*|  tag: \\"${IMAGE_TAG}\\"|" kubernetes/apps/online-boutique/values.yaml

                        git add kubernetes/apps/online-boutique/values.yaml
                        git commit -m "ci: update frontend image to ${IMAGE_TAG} [skip ci]"
                        git push https://${GIT_USER}:${GIT_TOKEN}@github.com/Dennis4507/cloudcommerce-devops.git HEAD:main
                    '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                docker rmi ${ECR_IMAGE} || true
                rm -rf app-source
            '''
        }
    }
}
```

The pipeline has stages (logical phases) and steps (commands). Each stage runs in sequence. If any step fails, subsequent stages are skipped and the build is marked failed.

## ECR Authentication — IAM Instance Profile (No Keys)

Jenkins authenticates to ECR using the IAM role attached to its EC2 instance — not stored access keys.

```
Jenkins EC2 instance
    │  has IAM role attached (provisioned by Terraform)
    │  role has ECR push permissions
    ▼
aws ecr get-login-password --region eu-central-1
    │  AWS CLI calls the instance metadata service (169.254.169.254)
    │  gets temporary credentials from the attached role
    ▼
docker login --username AWS --password-stdin <ecr-url>
    │  uses the temporary token to authenticate
    ▼
docker push <ecr-url>/cloudcommerce/frontend:abc123f
```

**Why this matters:**
- No access keys stored anywhere — no `AWS_ACCESS_KEY_ID` in Jenkins, no `.aws/credentials` on disk
- Temporary credentials rotate automatically (every 15 minutes by default)
- The IAM role defines exactly what ECR operations are permitted — principle of least privilege
- If the EC2 instance is terminated, the credentials terminate with it

The IAM role and its ECR permissions were provisioned by Terraform in Phase 1 — the `jenkins_ec2_role` resource in `terraform/modules/iam/`. This is one of the key security design decisions in the project.

## Trivy Image Scanning

Trivy scans the built Docker image for known vulnerabilities (CVEs) before it is pushed to ECR. It checks the OS packages, language libraries, and base image layers against multiple vulnerability databases.

```bash
trivy image \
    --exit-code 0 \         # 0 = report findings but don't fail the build
    --severity HIGH,CRITICAL \  # only report HIGH and CRITICAL severity
    --no-progress \         # suppress progress bars (cleaner in CI logs)
    ${ECR_IMAGE}
```

**`--exit-code 0` vs `--exit-code 1`:**
- `0` — always pass; Trivy reports findings but the pipeline continues to push
- `1` — fail the build if any HIGH/CRITICAL vulnerabilities are found

This project uses `--exit-code 0` initially to establish a baseline — identify what's present before deciding on a hard gate. In a production pipeline, switching to `--exit-code 1` would block pushes of vulnerable images.

**Installing Trivy on Jenkins via Ansible:**
```yaml
- name: Install Trivy
  shell: |
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
      | sh -s -- -b /usr/local/bin
  args:
    creates: /usr/local/bin/trivy  # idempotent — only runs if binary doesn't exist
```

## Two-Repo Structure

This project uses two GitHub repositories with clearly separated responsibilities:

```
Dennis4507/cloudcommerce-devops    ← infrastructure repo (DevOps team)
├── terraform/                       Terraform modules and environments
├── ansible/                         Ansible playbooks for server config
├── kubernetes/apps/online-boutique/ Helm chart — ArgoCD reads this
│   └── values.yaml                  Jenkins writes the image tag here
└── kubernetes/argocd/               ArgoCD Application manifests

Dennis4507/microservices-demo      ← application repo (development team)
├── src/                             12 microservice source directories
│   └── frontend/                    Jenkins builds from this path
└── Jenkinsfile                      CI pipeline definition
```

**Why separate repos:**
- Jenkins polls the application repo — a push to `microservices-demo` triggers a build
- ArgoCD watches the infrastructure repo — it never touches application source
- Development and infrastructure teams can work independently
- Access controls can be set per-repo — developers don't need infra access
- The Jenkinsfile lives with the application code it builds — if the build steps change, the same PR updates both the app and the pipeline

## The Two Commit IDs — Developer's vs Jenkins's

This is one of the most important details to understand in the pipeline. Two separate git commits happen for every build. They have different IDs, different purposes, and live in different repositories.

**Commit 1 — The developer's commit (triggers everything)**

```
Repository:  microservices-demo
Who made it: the developer
ID:          3f8a92c
Message:     "Fix checkout button colour"
Effect:      GitHub fires webhook at Jenkins
```

This commit ID is then used in two places by Jenkins:
- As the Docker image tag when pushing to ECR: `cloudcommerce/frontend:3f8a92c`
- As the value written inside values.yaml: `images.tag: "3f8a92c"`

**Commit 2 — Jenkins's own commit (triggers ArgoCD)**

```
Repository:  cloudcommerce-devops
Who made it: Jenkins (acting as a git user)
ID:          b7d3f91   ← a brand new ID generated by GitHub
Message:     "ci: update frontend image to 3f8a92c [skip ci]"
Effect:      ArgoCD detects this commit and deploys
```

Jenkins has its own git identity configured inside the Jenkinsfile:
```bash
git config user.email "jenkins@cloudcommerce.dev"
git config user.name "Jenkins"
```

Without this, git refuses to make a commit — every commit needs an author name and email. Jenkins's commit appears in the cloudcommerce-devops repository history as a real commit from "Jenkins."

**The full picture side by side:**

```
microservices-demo repo              cloudcommerce-devops repo
─────────────────────────            ────────────────────────────────────
commit 3f8a92c                       commit b7d3f91
by: Dennis4507                       by: Jenkins
"Fix checkout button colour"         "ci: update frontend image to 3f8a92c"
         │                                        │
         │ used as ECR tag                        │ ArgoCD detects this
         ▼                                        ▼
ECR: cloudcommerce/frontend:3f8a92c  values.yaml: images.tag: "3f8a92c"
```

**The audit trail this creates:**

At any point in time you can open the cloudcommerce-devops repo, look at the latest Jenkins commit (b7d3f91), read its message ("update frontend image to 3f8a92c"), go to microservices-demo, find commit 3f8a92c, and see exactly what the developer changed, when, and who pushed it. One ID connects the live running deployment all the way back to the original developer commit.

ArgoCD's own sync history also records which commit it deployed — so you have three layers of traceability:
```
ArgoCD synced at:  3:02pm  commit b7d3f91 in cloudcommerce-devops
b7d3f91 says:             "update frontend image to 3f8a92c"
3f8a92c says:             "Fix checkout button colour" by Dennis4507 at 2:58pm
ECR image:                cloudcommerce/frontend:3f8a92c  ← currently running
```

## The [skip ci] Pattern

When Jenkins builds an image and pushes it to ECR, it writes the new image tag back into `values.yaml` in the infrastructure repo and commits. Without a safeguard, this commit would trigger another Jenkins build, which would commit again, which would trigger again — an infinite loop.

The fix: add `[skip ci]` to the commit message:

```bash
git commit -m "ci: update frontend image to ${IMAGE_TAG} [skip ci]"
```

GitHub webhooks and most CI systems (including Jenkins with the right plugin) recognise `[skip ci]` and skip triggering a build for that commit. Jenkins polls only the `microservices-demo` repo, so this is mainly a safeguard against any webhook configuration that might be set up later.

## Jenkins Credentials Store

Jenkins has a built-in secrets manager called the Credentials Store. Sensitive values are stored here and injected into the pipeline at runtime — they never appear in Jenkinsfiles or build logs.

**Two credentials configured for this project:**

| Credential ID | Type | Used For |
|---|---|---|
| `aws-account-id` | Secret text | Constructing ECR registry URL |
| `github-token` | Username with password | Committing values.yaml back to GitHub |

**In the Jenkinsfile:**
```groovy
withCredentials([
    string(credentialsId: 'aws-account-id', variable: 'AWS_ACCOUNT_ID'),
    usernamePassword(credentialsId: 'github-token', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')
]) {
    sh 'echo $AWS_ACCOUNT_ID'  // masked in logs — appears as ****
}
```

Jenkins masks the values in logs automatically — if a credential value appears in stdout, Jenkins replaces it with `****`.

**What is NOT stored as credentials:**
- AWS access keys — ECR auth uses the IAM role on the EC2 instance (no keys needed)
- SSH keys — not used in this pipeline
- Docker registry passwords — ECR token is generated fresh each build from the IAM role

## GitHub Webhook — Triggering Jenkins on Push

Instead of Jenkins polling GitHub every few minutes, a webhook sends an immediate trigger when code is pushed.

Configuration in GitHub (`microservices-demo` repo → Settings → Webhooks):
- **Payload URL:** `http://3.127.90.169:8080/github-webhook/`
- **Content type:** `application/json`
- **Events:** Just the push event

Jenkins must have the GitHub plugin installed (included in suggested plugins). The pipeline job must have "GitHub hook trigger for GITScm polling" enabled.

**The webhook is a two-sided handshake — one side on GitHub, one side on Jenkins:**

**GitHub side** — configured once in GitHub → microservices-demo → Settings → Webhooks → Add webhook:
```
Payload URL:  http://3.127.90.169:8080/github-webhook/
Content type: application/json
Events:       Just the push event
```
This tells GitHub where to fire the notification when code is pushed. This is the only place the webhook URL is configured — it lives on GitHub, not inside Jenkins.

**Jenkins side** — configured in the pipeline job → Triggers section:
```
✓ GitHub hook trigger for GITScm polling
```
This checkbox tells the specific Jenkins pipeline job to wake up and run when a webhook notification arrives at port 8080. Without this checkbox, Jenkins receives the notification but ignores it and does nothing.

**Why the webhook URL is not configured inside Jenkins:**

Jenkins does not configure or know about the webhook address. Jenkins simply listens at port 8080 for any incoming notification at `/github-webhook/`. The GITScm polling checkbox is what connects that incoming signal to a specific pipeline job.

```
GitHub side:                         Jenkins side:
Payload URL configured               ✓ GITScm polling checkbox
in GitHub repo settings     ←──────→ ticked in pipeline job config

GitHub SENDS the notification        Jenkins RECEIVES and ACTS on it
```

Both halves must be in place. GitHub side without the Jenkins checkbox = notification arrives but nothing runs. Jenkins checkbox without GitHub side = Jenkins waits forever for a notification that never comes.

**GitHub-Projekt URL vs Repository URL — they are different:**

Inside the Jenkins job configuration there are two URL fields that look similar but do completely different things:

```
GitHub-Projekt URL:
  https://github.com/Dennis4507/microservices-demo
  → decorative only — adds a clickable GitHub link on the Jenkins job page
  → has no effect on how the pipeline runs

Repository URL (Pipeline script from SCM):
  https://github.com/Dennis4507/microservices-demo
  → functional — Jenkins clones the code from here every time it builds
  → this is what actually matters
```

Same URL, two different purposes. One is a shortcut. One is the actual build source.

**Flow after webhook is configured:**
```
Developer pushes to microservices-demo
    │
    ▼ GitHub fires webhook at http://3.127.90.169:8080/github-webhook/
Jenkins receives the notification
    │
    ▼ GITScm polling checkbox routes it to the cloudcommerce-frontend job
Pipeline starts building within seconds
```

Without the webhook, Jenkins would poll GitHub every few minutes — delay between push and build. With the webhook, the build starts within seconds of the push.

## CPU Credit Exhaustion — How t2/t3 Instances Throttle Under Load

This is different from an OOM (Out of Memory) kill and is important to understand when sizing CI servers.

**What CPU credits are:**

t2 and t3 instance types are "burstable" — they can use more CPU than their baseline for short periods by spending CPU credits. Credits accumulate when the instance is idle and drain when it runs above baseline.

| Instance | Baseline CPU | Credits earned/hr |
|---|---|---|
| t2.micro | 10% | 6 |
| t3.medium | 20% | 24 |

**What happens when credits run out:**

Under sustained heavy load (Docker build + Go compilation), a t2.micro burns through all its credits within minutes. Once exhausted, CPU is throttled to 10% baseline. A compilation that normally takes 70 seconds stretches to hours. The Jenkins JVM, running on the same throttled CPU, becomes too slow to serve web requests — the browser times out.

**This is NOT an OOM kill.** OOM kills a process when RAM is exhausted. CPU throttling is invisible — the process is still running, just extremely slowly. `dmesg | grep oom` returns nothing.

**How to diagnose:**

```bash
top
# load average >> number of CPUs  (e.g., 17.14 on a 2-core machine)
# high %wa (disk I/O wait — CPU-starved processes backing up)
# %id near 0% (no idle CPU)
```

**What this teaches:** t2/t3 burstable instances are designed for spiky, low-average workloads — web servers, APIs. CI/CD pipelines that compile code for sustained periods are the wrong use case. Use `m5`, `c5`, or `r5` types for build agents if using the master+agent architecture.

---

## Exit Code -1 — Jenkins Lost Connection vs Build Failure

When Jenkins shows `ERROR: script returned exit code -1`, this is **not** a build logic failure.

**What it means:** Jenkins lost track of the running process. The process was running, Jenkins restarted or the connection broke, and Jenkins can no longer determine the outcome.

**Real failure looks like:**
```
Step 5/8 : RUN apt-get install something
E: Unable to locate package something
ERROR: script returned exit code 1   ← positive number = real error
```

**Lost connection looks like:**
```
#13 [builder 6/6] RUN go build ...
Resuming build at ... after Jenkins restart
wrapper script does not seem to be touching the log file
ERROR: script returned exit code -1   ← negative = lost connection
```

The tells: `Resuming build after Jenkins restart` and `wrapper script does not seem to be touching the log file`. The build may have actually succeeded — Jenkins just doesn't know.

**What to do:** Fix the underlying cause (e.g., resize the instance), then re-run the build.

---

## Resizing EC2 via AWS Console vs Terraform

After discovering Jenkins was running on t2.micro (not t3.medium), there were two options to resize:

**Option A — Terraform:** Update `terraform.tfvars`, run `terraform apply`. For an instance type change, Terraform stops, resizes, and starts — it does NOT destroy the instance. However, after the AMI incident (Incident 2) where a Terraform apply destroyed both servers, the console approach was chosen as the safer option.

**Option B — AWS Console:** Stop instance → Actions → Instance Settings → Change Instance Type → Start. Surgical — changes exactly one thing.

**The rule:** Whichever option you use, always update the IaC to match immediately:

```hcl
# terraform.tfvars — must reflect reality
jenkins_instance_type = "t3.medium"
```

If the code still said `t2.micro` and someone ran `terraform apply` later, Terraform would resize back. Keeping IaC in sync prevents that drift.

---

## First Successful Pipeline Build — What Each Stage Did

Build triggered 2026-05-22, commit `e0cacb0c`, all 5 stages passed on t3.medium.

**Stage 1 — Checkout:** Jenkins cloned `microservices-demo`, checked out `e0cacb0c`.

**Stage 2 — Build Image (70 seconds):** Multi-stage Docker build. Builder stage: `golang:1.26.2-alpine` compiled the Go binary. Runtime stage: `gcr.io/distroless/static` — binary only, no shell, no OS packages. All Docker layers from previous attempts were cached — only step #13 (Go compilation) ran.

**Stage 3 — Trivy Scan:** Found 5 HIGH vulnerabilities in Go stdlib v1.26.2, all fixed in v1.26.3. `--exit-code 0` means pipeline continues — scan reports without blocking.

**Stage 4 — Push to ECR:** Image `cloudcommerce/frontend:e0cacb0c` pushed. ECR authenticated via IAM instance profile — no credentials.

**Stage 5 — Update values.yaml:** Jenkins cloned `cloudcommerce-devops`, updated `values.yaml` with new ECR tag, committed `977548c` with `[skip ci]`, pushed. This is the commit ArgoCD will detect on the next deploy.

**Post-build cleanup:** Docker image deleted from Jenkins disk. Cloned infra folder deleted — removes the GitHub token from the filesystem.

---

## Interview Talking Points

- "Jenkins is installed and configured via Ansible — the entire setup is reproducible from code, including Java runtime, GPG key import, repository configuration, and initial service startup"
- "Jenkins failed to start after installation because it requires Java 21 — it silently accepts installation with Java 17 but rejects it at runtime. Running the binary directly was the fastest way to surface that error"
- "ECR authentication uses the IAM role attached to the Jenkins EC2 instance — no access keys stored anywhere. The role is provisioned by Terraform and grants exactly the ECR permissions needed, nothing more"
- "The pipeline builds an image, scans it with Trivy, pushes to ECR, then writes the new image tag into values.yaml and commits. ArgoCD detects the commit and deploys — Jenkins and ArgoCD never talk directly"
- "I use the Jenkins Credentials Store for all sensitive values — AWS account ID and GitHub token are injected at pipeline runtime and masked in logs"
- "The [skip ci] flag in the values.yaml commit prevents an infinite loop — without it, Jenkins writing to the infra repo would trigger another Jenkins build"
- "The Jenkinsfile lives in the application repository alongside the code it builds — pipeline changes go through the same git review discipline as application changes"
- "Two repos keep concerns separated: developers push to microservices-demo, Jenkins triggers, ArgoCD reads cloudcommerce-devops. Each team's scope is clear"
- "Docker Pipeline is not included in the Jenkins suggested plugins — it must be installed separately. Without it, any pipeline that calls docker.build() will fail. I learned this during reinstallation when I had to manually search and install it after the suggested plugins completed"
- "Jenkins was upgraded from t2.micro (1GB RAM) to t3.medium (4GB RAM) after the Go compiler triggered an OOM kill during the first build. A t2.micro cannot run the Jenkins JVM and compile a Go binary at the same time — there is simply not enough memory"
