# ArgoCD and GitOps — Deep Dive

## What is GitOps?

GitOps is a deployment model where Git is the single source of truth for everything running in the cluster. The desired state of the cluster is defined in a Git repository. A GitOps tool continuously compares what's in Git against what's actually running and reconciles any differences.

**Traditional deployment (push model):**
```
CI pipeline builds image
→ Pipeline runs kubectl apply or helm upgrade
→ Cluster updated
→ No persistent record of what's running or who changed it
```

**GitOps (pull model):**
```
CI pipeline builds image
→ Pipeline updates values.yaml in Git (new image tag)
→ Git is now the source of truth
→ ArgoCD detects the change and syncs the cluster
→ Every deployment is a git commit — full audit trail
```

The key difference: in GitOps, the pipeline never talks directly to the cluster. It only writes to Git. ArgoCD handles the cluster side.

## Why GitOps?

- **Audit trail:** every deployment is a git commit with author, timestamp, and diff
- **Rollback:** rolling back is `git revert` — not a special command or procedure
- **Drift detection:** if someone manually changes the cluster, ArgoCD detects and corrects it
- **Recovery:** rebuilding the cluster means applying the same Git state — no undocumented steps
- **Separation of concerns:** CI (Jenkins) handles building; CD (ArgoCD) handles deploying; they never directly interact

## What is ArgoCD?

ArgoCD is a Kubernetes-native GitOps continuous delivery tool. It runs inside the cluster, watches Git repositories, and automatically syncs the cluster state to match what's defined in Git.

ArgoCD is itself deployed to Kubernetes — it's a set of pods running in the `argocd` namespace. It uses Kubernetes custom resources (`Application`) to define what it should manage.

## ArgoCD Architecture

```
GitHub Repository
    │  (ArgoCD polls every 3 minutes, or webhook on push)
    ▼
ArgoCD Controller (running in k3s)
    │  compares Git state vs cluster state
    ├─ If match → Synced (green)
    └─ If mismatch → Out of Sync → applies changes
```

**Core components:**
- **argocd-server** — the API server and web UI
- **argocd-repo-server** — clones and caches Git repositories
- **argocd-application-controller** — watches cluster state and triggers syncs
- **argocd-redis** — caches repository and application state
- **argocd-dex-server** — handles SSO/authentication

## The Application Resource

ArgoCD manages deployments through `Application` custom resources — Kubernetes objects that define what to deploy and where:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: online-boutique
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Dennis4507/cloudcommerce-devops.git
    targetRevision: HEAD       # branch, tag, or commit sha
    path: kubernetes/apps/online-boutique
  destination:
    server: https://kubernetes.default.svc   # in-cluster deployment
    namespace: online-boutique
  syncPolicy:
    automated:
      prune: true       # remove resources deleted from Git
      selfHeal: true    # revert manual cluster changes back to Git state
    syncOptions:
      - CreateNamespace=true
```

**Key fields:**
- `source.repoURL` — which Git repository ArgoCD watches
- `source.path` — the directory within the repo containing the manifests or Helm chart
- `source.targetRevision` — which branch/tag/commit to track (`HEAD` = latest on the default branch)
- `destination.server` — `https://kubernetes.default.svc` means the same cluster ArgoCD runs in
- `destination.namespace` — where to deploy the application
- `automated` — enables automatic sync without manual intervention
- `prune` — if a resource is removed from Git, ArgoCD removes it from the cluster
- `selfHeal` — if someone manually edits the cluster, ArgoCD reverts it to match Git
- `CreateNamespace` — ArgoCD creates the namespace if it doesn't exist

## Sync States

| State | Meaning |
|-------|---------|
| **Synced** | Cluster matches Git — everything is correct |
| **OutOfSync** | Git has changed but cluster hasn't been updated yet |
| **Progressing** | Sync is in progress — pods are being created/updated |
| **Degraded** | Resources are present but unhealthy (CrashLoopBackOff, etc.) |
| **Missing** | Resources defined in Git don't exist in the cluster at all |

## How ArgoCD Connects to GitHub — Credentials

When you register a repository inside ArgoCD, you provide a credential — either a GitHub PAT or an SSH key. This gives ArgoCD access to read the repository.

**This credential is read-only.** ArgoCD never writes to GitHub. Its entire job is to read the repository and deploy what it finds. This is intentional and important:

```
Jenkins PAT    → write access  → Jenkins needs to UPDATE values.yaml on GitHub
ArgoCD PAT     → read access   → ArgoCD only needs to READ values.yaml from GitHub
```

These are two completely separate credentials stored in two different places. If ArgoCD's credential were ever compromised, an attacker could only read the repository — they could not change anything.

**What ArgoCD watches — the whole folder, not just values.yaml:**

ArgoCD is pointed at a folder path, not a specific file:
```yaml
source:
  path: kubernetes/apps/online-boutique   # ← watches this entire folder
```

It watches every file in that folder. If Chart.yaml, values.yaml, or any template file changes, ArgoCD detects it and syncs. In practice the only file Jenkins ever changes is values.yaml — so that is almost always what triggers ArgoCD. But technically any change to anything in that folder would trigger a sync.

## ArgoCD and Helm

ArgoCD has Helm built-in. When a path contains a `Chart.yaml`, ArgoCD automatically detects it as a Helm chart and:

1. Runs `helm template` internally using the `values.yaml` in the same directory
2. Applies the resulting Kubernetes YAML to the destination namespace
3. Tracks all the rendered resources for sync status

Helm does not need to be installed on the cluster — ArgoCD handles rendering natively.

## Installing ArgoCD — Lessons Learned

ArgoCD installation exposes two common failure modes with `kubectl apply`:

### Issue 1 — Annotation Size Limit

Default `kubectl apply` (client-side mode) stores the entire manifest as an annotation on the resource for tracking purposes. ArgoCD's CRDs are large enough to exceed Kubernetes' 262144 byte annotation limit:

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Fix:** Use server-side apply — field tracking moves to the server, no annotation written:
```bash
kubectl apply --server-side -f install.yaml
```

### Issue 2 — Field Manager Conflict

If client-side apply ran first (creating resources with manager `kubectl-client-side-apply`), switching to server-side apply creates a conflict — two managers claim the same fields:

```
conflict with "kubectl-client-side-apply" using apps/v1
```

**Fix:** Add `--force-conflicts` to take ownership of all conflicting fields:
```bash
kubectl apply --server-side --force-conflicts -f install.yaml
```

This is the documented solution for CRD-heavy operators like ArgoCD, Prometheus Operator, and cert-manager.

## Why Ansible for ArgoCD Installation

ArgoCD is a Kubernetes application, so the temptation is to install it with a one-off `kubectl apply` command. Writing an Ansible playbook instead:

- Makes the installation reproducible — one command rebuilds the full GitOps layer on any cluster
- Documents every step — no undocumented manual actions
- Keeps consistent with how all other infrastructure in this project is managed
- Handles all the `--server-side --force-conflicts` flags declaratively

## Accessing ArgoCD

ArgoCD server is exposed on NodePort 30080 in this project. This was configured by patching the argocd-server service:

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"targetPort":8080,"nodePort":30080,"protocol":"TCP"}]}}'
```

Access: `https://63.184.235.88:30080`

The TLS warning is expected — ArgoCD uses its own self-signed certificate (separate from the k3s cluster certificate).

**Initial admin password:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

The password is stored in a Kubernetes secret and printed by the Ansible playbook. After first login, create a permanent admin account and delete the initial secret.

## The GitOps Flow in This Project

```
1. Developer pushes code to GitHub
          ↓
2. GitHub webhook triggers Jenkins
          ↓
3. Jenkins:
   - Builds Docker image
   - Scans with Trivy
   - Pushes to ECR
   - Updates kubernetes/apps/online-boutique/values.yaml:
       images:
         tag: "new-commit-sha"
   - Commits and pushes to GitHub
          ↓
4. ArgoCD detects the commit (polls every 3 min)
          ↓
5. ArgoCD renders the Helm chart with new values.yaml
          ↓
6. ArgoCD applies the new Deployment to k3s
          ↓
7. k3s pulls the new image from ECR
          ↓
8. Rolling update — new pods up, old pods down
```

Jenkins and ArgoCD never talk to each other. Their only connection is the Git repository. This is the GitOps separation of concerns.

## Synced vs Healthy — Two Separate States

ArgoCD tracks two independent dimensions for every application:

| Dimension | What it means | Green = |
|-----------|--------------|---------|
| **Sync Status** | Does the cluster match Git? | Cluster state matches values.yaml |
| **Health Status** | Are the resources actually working? | All pods Running and Ready |

**You can be Synced but Degraded.** This is an important distinction:
- ArgoCD applied the Helm chart correctly → **Synced** ✓
- All pods are in `ImagePullBackOff` or `Pending` → **Degraded** ✗

ArgoCD's job is to apply what's in Git. Whether the application actually works after that is the health check's job. When pods can't pull images, ArgoCD correctly reports: "I applied what you told me to, but the result is unhealthy."

This separation matters in debugging: if ArgoCD shows **OutOfSync**, the problem is between Git and the cluster (manifest, Helm rendering, permissions). If ArgoCD shows **Synced + Degraded**, the problem is inside the application — image pull failures, crash loops, failed readiness probes.

## What ArgoCD Watches vs What Jenkins Watches

A critical separation that prevents confusion:

```
microservices-demo repo  ←── Jenkins watches this
  (application code, Dockerfiles)
  Developer pushes here → Jenkins builds images

cloudcommerce-devops repo ←── ArgoCD watches this
  (Helm charts, values.yaml, Kubernetes manifests)
  Jenkins writes here (automated values.yaml commit)
  ArgoCD reads here → deploys to k3s
```

Pushing a config change to `cloudcommerce-devops` does **not** trigger Jenkins — Jenkins has no awareness of that repo. It only triggers ArgoCD. Pushing code to `microservices-demo` does **not** trigger ArgoCD directly — it triggers Jenkins, which then writes to `cloudcommerce-devops`, which ArgoCD then picks up.

The two tools are connected only through Git — they never talk to each other directly.

## ArgoCD Polling — How Fast It Detects Changes

ArgoCD polls the Git repository every **3 minutes** by default. This means after Jenkins pushes the updated `values.yaml`, there can be up to a 3-minute delay before ArgoCD detects the change and begins syncing.

For faster response, a GitHub webhook can be configured to notify ArgoCD on every push — this reduces detection time to seconds. Without a webhook, the 3-minute poll is the default behaviour.

You can also force a sync manually:
```bash
kubectl get application online-boutique -n argocd
# or through the ArgoCD UI → Sync button
```

## Interview Talking Points

- "ArgoCD is the CD layer in our platform — it watches GitHub and automatically syncs the cluster to match whatever is in the repository. Every deployment is traceable to a git commit."
- "The GitOps model means Jenkins never talks to the cluster directly — it writes the new image tag to values.yaml and commits to GitHub. ArgoCD picks up the change and handles the deployment."
- "selfHeal: true means if someone manually changes a resource in the cluster, ArgoCD reverts it back to match Git within minutes. Git is always the source of truth."
- "ArgoCD installation required --server-side --force-conflicts because the ApplicationSet CRD exceeds the default kubectl annotation size limit. This is a documented issue with CRD-heavy operators."
- "I installed ArgoCD via Ansible rather than a one-off kubectl command — the playbook is the install record, and re-running it on a fresh cluster restores the full GitOps layer automatically."
- "Rollback in GitOps is git revert — no special procedure, no muscle memory required, full audit trail preserved."
