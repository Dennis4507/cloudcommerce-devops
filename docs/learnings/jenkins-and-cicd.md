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

Jenkins runs as a server (on our EC2 t2.micro) and exposes a web UI at port 8080. Pipelines are defined in a `Jenkinsfile` — a Groovy-based DSL that sits in the repository root.

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
- Blue Ocean (modern pipeline UI)
- Docker Pipeline
- Workspace management

**Select plugins to install** — choose manually from the full list.

For initial setup, suggested plugins is the correct choice. Selecting manually risks missing transitive dependencies and produces a half-configured Jenkins with cryptic errors when you try to build pipelines. Additional plugins can always be added later.

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

## The Jenkinsfile

A Jenkinsfile defines the pipeline as code. It lives in the root of the repository and is written in Groovy DSL:

```groovy
pipeline {
    agent any

    environment {
        ECR_REGISTRY = "${AWS_ACCOUNT_ID}.dkr.ecr.eu-central-1.amazonaws.com"
        IMAGE_TAG = "${GIT_COMMIT}"
    }

    stages {
        stage('Build') {
            steps {
                sh 'docker build -t ${ECR_REGISTRY}/cloudcommerce/frontend:${IMAGE_TAG} .'
            }
        }
        stage('Scan') {
            steps {
                sh 'trivy image ${ECR_REGISTRY}/cloudcommerce/frontend:${IMAGE_TAG}'
            }
        }
        stage('Push') {
            steps {
                sh 'docker push ${ECR_REGISTRY}/cloudcommerce/frontend:${IMAGE_TAG}'
            }
        }
    }
}
```

The pipeline has stages (logical phases) and steps (commands). Each stage runs in sequence. If any step fails, subsequent stages are skipped and the build is marked failed.

## Interview Talking Points

- "Jenkins is installed and configured via Ansible — the entire setup is reproducible from code, including Java runtime, GPG key import, repository configuration, and initial service startup"
- "Jenkins failed to start after installation because it requires Java 21 — it silently accepts installation with Java 17 but rejects it at runtime. Running the binary directly was the fastest way to surface that error"
- "I use the Jenkins Credentials Store for all sensitive values — AWS credentials, tokens, and passwords are injected at pipeline runtime and never appear in Jenkinsfiles or logs"
- "The jenkins user needs docker group membership to run Docker commands in pipelines — this is handled declaratively in the Ansible playbook"
- "The Jenkinsfile lives in the same repository as the application code — pipeline changes go through the same git review discipline as application changes"
