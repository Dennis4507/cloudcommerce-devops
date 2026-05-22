# How Everything Connects — A Beginner's Guide to This Project

This document explains the entire project in plain English. No prior tech knowledge required.
Read it top to bottom and by the end you will understand exactly how a code change on a developer's laptop ends up running as a live website — automatically, securely, and without anyone touching a server manually.

---

## The Two Buildings

Everything in this project runs across two servers on AWS (Amazon's cloud). Think of them as two buildings on the same street.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   BUILDING 1: THE KITCHEN              BUILDING 2: THE PIZZA SHOP       │
│   Jenkins Server                       k3s Server                       │
│   IP: 3.127.90.169                     IP: 63.184.235.88                │
│   Size: t3.medium (4GB RAM)            Size: t3.medium (4GB RAM)        │
│                                                                          │
│   Job: build, scan, package,           Job: run the live website,       │
│   and deliver new versions             serve customers, deploy           │
│   of the application                   new versions when told           │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

These two buildings **never talk to each other directly**. There is no cable between them. They communicate through two shared places that both can access — GitHub (the shared noticeboard) and ECR (the shared warehouse). This is intentional — either building can go down and the other keeps working.

---

## The Two Repositories on GitHub

The project uses two completely separate GitHub repositories with different jobs:

```
microservices-demo         ← the application code
│                            12 programs that make up the online shop
│                            the Jenkinsfile (Jenkins's instruction manual)
│                            developers push here when they change code
│
cloudcommerce-devops       ← the infrastructure code
    │
    ├── terraform/           code that built the two AWS servers
    ├── ansible/             code that installed software on the servers
    └── kubernetes/
        ├── argocd/          ArgoCD application definitions
        └── apps/
            └── online-boutique/
                ├── Chart.yaml     Helm chart ID card
                ├── values.yaml    ← Jenkins writes here after every build
                └── templates/     blank order forms ArgoCD fills in
```

Developers only touch `microservices-demo`. Jenkins reads from `microservices-demo` to build, and writes to `cloudcommerce-devops` to update values.yaml. ArgoCD only reads from `cloudcommerce-devops`. Each repo has a clear owner and purpose.

---

## The Complete Pipeline — Step by Step

This is the full journey from a developer pushing code to it running live. The developer only does Step 1. Every other step is automatic.

---

### Step 1 — Developer pushes code to GitHub

```
Repository:   microservices-demo
Who:          the developer (Dennis4507)
Action:       git push (sends new or changed code to GitHub)
Result:       GitHub generates a unique commit ID → 3f8a92c
```

The commit ID `3f8a92c` is GitHub's unique fingerprint for this exact push. It records who pushed, when, and what files changed. This same ID will travel through every step of the pipeline — it is the thread that connects the live running website all the way back to the developer's keyboard.

---

### Step 2 — GitHub notifies Jenkins via webhook

GitHub does not wait for Jenkins to ask "any new code?" The moment the developer pushes, GitHub fires a notification directly at Jenkins's address. This is called a webhook.

```
FROM:    GitHub
TO:      http://3.127.90.169:8080/github-webhook/
MESSAGE: New code pushed to microservices-demo
         Commit ID: 3f8a92c
         By: Dennis4507
         Files changed: src/frontend/main.go
```

**The webhook is a two-sided handshake — one side on GitHub, one side on Jenkins:**

**GitHub side** (configured once in GitHub → microservices-demo → Settings → Webhooks → Add webhook):
```
Payload URL:  http://3.127.90.169:8080/github-webhook/
Content type: application/json
Events:       Just the push event
```
This is GitHub's side — it tells GitHub where to send the notification when code is pushed.

**Jenkins side** (configured in the pipeline job → Triggers section):
```
✓ GitHub hook trigger for GITScm polling
```
This checkbox is Jenkins's side — it tells that specific Jenkins job to wake up and run when a webhook notification arrives. Without this checkbox ticked, Jenkins receives the notification but ignores it completely and does nothing.

**Why the webhook URL is not configured inside Jenkins:**

Jenkins does not need to know about the webhook at all. Jenkins simply sits at port 8080 listening for any incoming notification. When GitHub fires the webhook, Jenkins receives it at `/github-webhook/`. The GITScm polling checkbox is what tells the specific pipeline job to react to it.

Think of it as a doorbell system:
```
GitHub               = the person pressing the doorbell
Port 8080            = the wire carrying the signal into the building
github-webhook/      = the doorbell receiver on the wall
GITScm polling ✓     = the speaker in the specific room that reacts when the bell rings
```

Jenkins does not configure the doorbell on GitHub's side — GitHub does. Jenkins only needs to have the right speaker (GITScm polling checkbox) turned on in the right room (the pipeline job). Both halves must be in place for the notification to trigger a build.

---

### Step 3 — Jenkins reads its instruction manual (the Jenkinsfile)

The Jenkinsfile lives inside the `microservices-demo` repository alongside the application code. It is Jenkins's step-by-step recipe book — it tells Jenkins exactly what to do every time a push arrives, in what order, without skipping anything.

```
Jenkinsfile says:
  Step 1 — Clone the code from GitHub
  Step 2 — Build a Docker image and label it with the commit ID
  Step 3 — Scan the image for security vulnerabilities (Trivy)
  Step 4 — Push the image to ECR (the warehouse)
  Step 5 — Update values.yaml in cloudcommerce-devops with the new tag
  Step 6 — Commit and push that update back to GitHub
```

Jenkins does not decide any of this on its own. It follows the recipe. If the recipe changes (someone edits the Jenkinsfile), that change goes through GitHub review just like any other code change.

---

### Step 4 — Jenkins builds the Docker image and labels it

Jenkins builds a Docker image — a sealed, portable box containing the new version of the program plus everything it needs to run. The box gets labelled with the developer's commit ID from Step 1:

```
Image label:  cloudcommerce/frontend:3f8a92c
```

The label `3f8a92c` is not random. It is the exact commit ID from the developer's push. This is intentional — the label on the box tells you exactly what code is inside and where it came from.

---

### Step 5 — Jenkins runs a security scan (Trivy)

Before the image goes anywhere near the warehouse, Jenkins runs Trivy — a security scanner that opens the box and checks every layer of the image for known vulnerabilities. If it finds critical problems, the pipeline stops immediately. The developer is alerted. The unsafe image is discarded. Nothing dangerous ever reaches the warehouse or the live website.

---

### Step 6 — Jenkins pushes the labelled image to ECR

ECR (Elastic Container Registry) is Amazon's private warehouse sitting between the two buildings. Jenkins pushes the labelled, scanned box there.

To push to ECR, Jenkins needs the full warehouse address. That address includes the AWS account ID:
```
<your-account-id>.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend:3f8a92c
└── account ID ──┘└── region ──────────────────────┘└── project ─┘└── service ─┘└─ tag ─┘
```

This is why the AWS account ID is stored as a credential inside Jenkins — it is a required part of the delivery address. Without it Jenkins cannot construct the address and the push fails.

The warehouse shelves keep every version ever built:
```
cloudcommerce/frontend:3f8a92c  ← just arrived
cloudcommerce/frontend:def5678  ← previous version
cloudcommerce/frontend:ghi9012  ← older version
```

Old versions are never deleted. This means you can always roll back to any previous version just by pointing at an older tag.

---

### Step 7 — Jenkins updates values.yaml with the developer's commit ID

Jenkins now switches to the completely separate `cloudcommerce-devops` repository — not the repo the developer pushed to. This is the infrastructure repo where the Helm chart and values.yaml live.

Jenkins opens values.yaml and writes the developer's commit ID as the image tag:

```yaml
images:
  tag: "3f8a92c"   ← the exact same commit ID from Step 1
```

The value written INSIDE values.yaml is `3f8a92c` — the developer's commit ID. The same ID that is stamped on the ECR image. This is what connects the warehouse shelf to the order form — the same label.

If only the frontend changed, only the frontend line updates. The other 11 services stay untouched:

```
frontend image tag:          3f8a92c   ← Jenkins just changed this
cartservice image tag:       def5678   ← untouched
checkoutservice image tag:   def5678   ← untouched
paymentservice image tag:    def5678   ← untouched
productcatalog image tag:    def5678   ← untouched
recommendationservice tag:   def5678   ← untouched
shippingservice image tag:   def5678   ← untouched
emailservice image tag:      def5678   ← untouched
currencyservice image tag:   def5678   ← untouched
adservice image tag:         def5678   ← untouched
loadgenerator image tag:     def5678   ← untouched
redis image tag:             def5678   ← untouched
```

ArgoCD will see only the frontend line changed and only redeploy the frontend. The other 11 services keep running without interruption.

values.yaml also controls much more than just image tags. Every service has its own CPU and memory settings:

```yaml
frontend:
  create: true       ← toggle: set false to completely skip this service
  resources:
    requests:
      cpu: 100m      ← minimum CPU guaranteed to this service
      memory: 64Mi   ← minimum memory guaranteed
    limits:
      cpu: 200m      ← maximum CPU it is allowed to use
      memory: 128Mi  ← maximum memory allowed
```

Jenkins only touches the image tag lines. All other settings stay as configured.

---

### Step 8 — Jenkins makes its own git commit and pushes to GitHub

This is the most important step to understand clearly. Jenkins does not silently update values.yaml in the background. It makes a real, proper git commit and pushes it to GitHub — exactly like a developer would.

For git to allow any commit, the person or program making it must have a registered name and email. Jenkins sets its own git identity before committing:

```bash
git config user.email "jenkins@cloudcommerce.dev"
git config user.name "Jenkins"
```

Without this, git refuses to commit. Jenkins then commits and pushes:

```bash
git commit -m "ci: update frontend image to 3f8a92c [skip ci]"
git push https://<PAT>@github.com/Dennis4507/cloudcommerce-devops.git HEAD:main
```

This push generates a brand new commit ID — something like `b7d3f91`. This is Jenkins's own commit ID. Completely separate from the developer's `3f8a92c`.

**There are now two separate commits in two separate repositories:**

```
microservices-demo repo:
  commit 3f8a92c
  by: Dennis4507
  message: "Fix checkout button colour"
  effect: triggered Jenkins via webhook

cloudcommerce-devops repo:
  commit b7d3f91
  by: Jenkins <jenkins@cloudcommerce.dev>
  message: "ci: update frontend image to 3f8a92c [skip ci]"
  effect: ArgoCD detects this and deploys
```

The value INSIDE values.yaml is `3f8a92c` (developer's ID). Jenkins's own commit that pushed that file is `b7d3f91` (Jenkins's ID). These are different. The developer's ID is the receipt number on the pizza box. Jenkins's ID is the delivery note for the order form update.

**Why `[skip ci]` must be in Jenkins's commit message:**
Jenkins watches `microservices-demo` for new pushes. If it also responded to pushes on `cloudcommerce-devops`, then Jenkins's own push (b7d3f91) would trigger a new build, which would push again, which would trigger again — an infinite loop of builds. `[skip ci]` tells any CI system: do not trigger a build for this commit. It is the safety net that stops the loop.

**Why Jenkins needs the PAT for this push:**
GitHub does not let anyone push to a repository without proving their identity. The GitHub Personal Access Token (PAT) stored in Jenkins's credentials is embedded in the push URL as a password. Without it, GitHub rejects the push with a 403 error. ArgoCD would never see a change. The image would sit in the ECR warehouse forever, uncollected.

---

### Step 9 — ArgoCD detects Jenkins's commit

ArgoCD is a program running inside the k3s server (Building 2 — the pizza shop). It has one job: watch a GitHub repository and keep the cluster in sync with whatever is in that repository.

When ArgoCD was first set up, it was given three pieces of information:

```
Repository URL:  https://github.com/Dennis4507/cloudcommerce-devops
Path:            kubernetes/apps/online-boutique
Branch:          main
```

This is the address of the noticeboard ArgoCD watches. ArgoCD checks this folder continuously — either polling every 3 minutes or being notified instantly via its own webhook from GitHub.

**How ArgoCD authenticates with GitHub:**

ArgoCD uses its own read-only GitHub credential registered inside ArgoCD when the repository was first connected. This is completely separate from Jenkins's `github-token` credential:

```
Jenkins  github-token    → Username: Dennis4507 / Password: PAT
                         → write access — can push commits to GitHub
                         → stored inside Jenkins

ArgoCD credential        → PAT or SSH key
                         → read-only access — can only read the repository
                         → stored inside ArgoCD
```

ArgoCD never writes to GitHub. It only reads. If ArgoCD's credential were ever compromised, an attacker could only read the repository — they could not change any files.

**What ArgoCD watches — the whole folder, not just values.yaml:**

ArgoCD watches everything inside `kubernetes/apps/online-boutique`:

```
kubernetes/apps/online-boutique/
├── Chart.yaml      ← ArgoCD reads this
├── values.yaml     ← ArgoCD reads this (Jenkins just updated it)
└── templates/      ← ArgoCD reads all of these
    ├── frontend.yaml
    ├── cartservice.yaml
    └── ...
```

Any file change in that folder triggers ArgoCD. In practice Jenkins only ever changes values.yaml, so that is almost always the trigger. But the whole folder is watched.

The moment ArgoCD detects Jenkins's commit (`b7d3f91`) it moves to the next step.

---

### Step 10 — ArgoCD reads the Helm chart and values.yaml together

ArgoCD now reads all the files in `kubernetes/apps/online-boutique` together. This is where the Helm chart and values.yaml combine to produce the actual deployment instructions.

**The Helm chart — the blank order form:**

The Helm chart is a folder of template files. Each template file describes one Kubernetes resource — a Deployment, a Service, networking rules. But every specific value is written as a blank placeholder:

```yaml
# templates/frontend.yaml — actual line from this project
image: {{ .Values.images.repository }}/{{ .Values.frontend.name }}:{{ .Values.images.tag }}
```

On its own this template is useless. It has blanks where the actual values should be. Those blanks get filled in from values.yaml.

**values.yaml — the filled-in order:**

```yaml
images:
  repository: <account-id>.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce
  tag: "3f8a92c"      ← Jenkins just wrote this in Step 7

frontend:
  name: frontend
  create: true
  resources:
    requests:
      cpu: 100m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

**ArgoCD combines them:**

ArgoCD takes the Helm chart templates and fills every `{{ .Values.xxx }}` blank using values.yaml. The result is a complete, concrete instruction set:

```yaml
# What ArgoCD produces after combining chart + values:
image: <account-id>.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend:3f8a92c
resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

ArgoCD now has everything it needs to tell k3s exactly what to run, what version, how much resource to give it, what port it uses, and how it connects to the other 11 services.

**ArgoCD compares desired state vs current state:**

ArgoCD looks at what the combined chart + values says should be running and compares it against what is actually running in k3s right now:

```
Desired state (from values.yaml):   frontend:3f8a92c
Current state (running in k3s):     frontend:def5678
Result:                             OUT OF SYNC → deploy needed
```

Only the frontend is out of sync. The other 11 services match their values.yaml entries. ArgoCD only touches the frontend.

---

### Step 11 — ArgoCD instructs k3s to pull the new image from ECR

ArgoCD runs inside the k3s server itself. It does not push instructions from outside — it applies them directly to the cluster from within. This is the pull model of GitOps: the cluster pulls its own desired state from Git rather than having someone push commands at it from outside.

ArgoCD sends the deployment instruction to k3s:

```
Deploy: cloudcommerce/frontend:3f8a92c
Source: <account-id>.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend:3f8a92c
```

k3s receives this and goes to the ECR warehouse to collect the box labelled `3f8a92c`. k3s authenticates with ECR using the IAM role attached to the k3s EC2 instance — no passwords stored anywhere, just the AWS role that was provisioned by Terraform at the start.

---

### Step 12 — k3s swaps the old version for the new one with zero downtime

k3s does not shut down the old frontend and then start the new one. That would cause downtime. Instead it runs both simultaneously during the transition:

```
Phase 1:  Old frontend (def5678) running → serving 100% of traffic
          New frontend (3f8a92c) starting up alongside it

Phase 2:  New frontend passes health checks (responds correctly on port 8080)
          k3s begins shifting traffic — 50% old, 50% new

Phase 3:  Traffic fully shifted to new frontend (3f8a92c) — serving 100%
          Old frontend (def5678) shut down and removed

Result:   Only new version running. Zero customer interruption.
```

**The health check k3s runs before shifting traffic:**

k3s calls the frontend's health endpoint before sending any real traffic to it:
```
GET /_healthz   → must return 200 OK
```

If the new version fails this check — meaning something in the code is broken and the service crashes on startup — k3s stops the rollout. The old version keeps running. No broken code ever reaches customers. The developer gets an alert that the deployment failed.

This is the final step. The live website is now running `frontend:3f8a92c`. The developer's code change is live. No human touched any server. The entire journey from git push to live deployment happened automatically.

---

## The Full Audit Trail

Every step leaves a permanent, traceable record. At any point you can work backwards from the live running image to the exact line of code a developer changed:

```
k3s is currently running:
  cloudcommerce/frontend:3f8a92c
            │
            ▼
ECR warehouse confirms:
  image tagged 3f8a92c was pushed at 2:59pm
            │
            ▼
ArgoCD sync history shows:
  synced commit b7d3f91 from cloudcommerce-devops at 3:02pm
            │
            ▼
Commit b7d3f91 message says:
  "ci: update frontend image to 3f8a92c [skip ci]" by Jenkins
            │
            ▼
Commit 3f8a92c in microservices-demo says:
  "Fix checkout button colour" by Dennis4507 at 2:58pm
  Files changed: src/frontend/templates/index.html line 47
```

One unbroken chain. From the live running image all the way back to the developer, the file, the line, and the time. Nothing is anonymous. Nothing is undocumented.

---

## The Credentials — What Each One Does and Why

There are three credentials in this pipeline. Each one exists for a specific reason and its absence breaks a specific part of the chain.

### Credential 1 — `github-token` — Jenkins's Write Badge

```
Stored in:  Jenkins credentials store (Global scope)
Type:       Username with password
Username:   Dennis4507
Password:   your GitHub Personal Access Token (PAT)
Used in:    Step 8 — Jenkins's git push to cloudcommerce-devops
```

Jenkins needs this to push the values.yaml update back to GitHub. When Jenkins runs its git push in Step 8, it authenticates by embedding these details in the push URL:

```bash
git push https://Dennis4507:<PAT>@github.com/Dennis4507/cloudcommerce-devops.git HEAD:main
```

GitHub sees `Dennis4507` as the identity and the PAT as the password. If the PAT is wrong, expired, or has no write permission, GitHub returns a 403 error. The push fails. values.yaml never gets updated. ArgoCD never detects a change. The new image sits in ECR forever, uncollected.

This is stored as a Jenkins credential and not hardcoded in the Jenkinsfile so it never appears in the code, never gets committed to Git, and never shows up in build logs. Jenkins injects it at runtime and masks it in logs with `****`.

---

### Credential 2 — `aws-account-id` — The Warehouse Address

```
Stored in:  Jenkins credentials store (Global scope)
Type:       Secret text
Value:      your 12-digit AWS account number
Used in:    Step 6 — Jenkins pushing the Docker image to ECR
```

Jenkins needs this to construct the full ECR warehouse address when pushing the image. The account ID is a required part of that address:

```
<your-account-id>.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce/frontend:3f8a92c
└── account ID ──┘
```

Without the account ID, Jenkins cannot build this address and the image push to ECR fails. The image never reaches the warehouse. k3s has nothing to collect.

Stored as a credential because your AWS account ID is sensitive. An attacker who knows it can use it as one piece of a larger puzzle to target your AWS resources. It should never appear in code or logs.

---

### Credential 3 — ArgoCD GitHub Credential — Read-Only Access

```
Stored in:  ArgoCD (not Jenkins)
Type:       PAT or SSH key
Permission: read-only
Used in:    Step 9 — ArgoCD reading cloudcommerce-devops on GitHub
```

ArgoCD needs this to read the `cloudcommerce-devops` repository at `https://github.com/Dennis4507/cloudcommerce-devops`. Without it, ArgoCD cannot see values.yaml or the Helm chart and has no idea what to deploy.

This credential only needs read access — ArgoCD never writes to GitHub. It is registered inside ArgoCD when the repository is first connected.

**The key difference between credential 1 and credential 3:**

```
github-token (Jenkins)       → write access → Jenkins PUSHES commits to GitHub
ArgoCD credential            → read access  → ArgoCD READS the repo from GitHub
```

Two separate credentials. Two separate permission levels. Two separate places they are stored. If ArgoCD's credential were compromised, an attacker could only read the repository — they could not change anything.

---

## Every Tool in One Line

| Tool | Pizza restaurant equivalent | What it actually does |
|---|---|---|
| **GitHub** | The noticeboard both buildings share | Stores all code, tracks every change, connects the kitchen to the shop |
| **Webhook** | The bell that rings in the kitchen when an order arrives | Notifies Jenkins the instant new code is pushed |
| **Jenkins** | The head chef | Builds, scans, packages, and delivers code automatically |
| **Jenkinsfile** | The recipe book on the kitchen counter | Tells Jenkins exactly what steps to follow every build |
| **Docker** | The packaging machine | Seals each program into a portable box that runs identically anywhere |
| **Image tag** | The receipt label on every pizza box | The developer's commit ID stamped on the image — traces it back to the exact code |
| **ECR** | The warehouse between the two buildings | Stores every built image so the kitchen and shop share without talking directly |
| **Trivy** | The food safety inspector | Scans every image for security vulnerabilities before it leaves the kitchen |
| **Helm chart** | The blank order form — printed once, never written on | Template that describes the structure of the entire application |
| **values.yaml** | The filled-in order Jenkins writes after every build | Records which version of each service to run, plus CPU/memory settings |
| **ArgoCD** | The shop manager watching the noticeboard | Detects values.yaml changes and deploys the right version to k3s |
| **k3s** | The shop floor | Runs all 12 services and serves the live website to users |
| **Jenkins PAT** | Jenkins's staff badge to write on the noticeboard | Write-access GitHub token so Jenkins can push the values.yaml update |
| **AWS Account ID** | Part of the warehouse delivery address | Required to build the ECR URL so Jenkins knows where to send images |
| **ArgoCD credential** | The shop manager's reading pass | Read-only GitHub access so ArgoCD can see values.yaml and the Helm chart |
| **Terraform** | The construction company | Built both AWS servers, the network, the ECR warehouse — all from code |
| **Ansible** | The interior fitter | Installed Jenkins, k3s, ArgoCD, Docker, Trivy — all from code, repeatable |

---

## What Happens If Each Piece Goes Down

| Component | What stops | What keeps working |
|---|---|---|
| **Jenkins (Kitchen)** | No new builds. New code pushes pile up unprocessed. | The live website keeps serving whatever was last deployed. |
| **k3s (Pizza Shop)** | The live website goes down. | Jenkins keeps building and pushing images to ECR. They wait. |
| **ArgoCD** | New deployments stop. values.yaml changes go unread. | k3s keeps running whatever is already deployed. |
| **ECR (Warehouse)** | Jenkins cannot push. k3s cannot pull new images. | Both buildings stay online on current versions. |
| **GitHub (Noticeboard)** | Jenkins cannot clone. ArgoCD cannot read. Everything stops. | Whatever is currently deployed keeps serving users. |

The most critical component for users is **k3s**. The most critical for developers is **GitHub**.

---

## Why Build All This Instead of Copying Files Manually?

Manual deployments break under real-world pressure:
- You can only deploy when a human is awake and available
- Every person does it slightly differently — inconsistent results
- Rollback under pressure at 2am is a nightmare of manual steps
- Security scanning gets skipped when there is a deadline
- Nobody knows exactly what version is running or who put it there

This automated pipeline means:
- Developer pushes code and it is live in minutes — zero human steps after the push
- Every build follows exactly the same recipe — no variation, no skipped steps
- Rollback is changing one tag in values.yaml — two minutes of work
- Trivy runs on every single build — security cannot be skipped, ever
- Every deployment is fully documented: who pushed, when, what commit, what image tag

This pattern is called **GitOps** — Git is the single source of truth for everything running in the cluster. It is the industry standard at Netflix, Spotify, Google, and most companies running software at scale. The tools differ (some use Flux instead of ArgoCD, GitHub Actions instead of Jenkins) but the pattern — code push triggers build triggers deployment via Git — is universal.

---

*This project was built as a hands-on learning exercise to understand and practise these industry-standard DevOps patterns.*
