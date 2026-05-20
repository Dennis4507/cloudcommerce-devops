# Helm — Deep Dive

## What is Helm?

Helm is the package manager and templating engine for Kubernetes. It solves the problem of managing complex Kubernetes deployments that span many files and need to work differently across environments.

**Without Helm:**
```
kubernetes-manifests/
├── frontend.yaml        ← image tag hardcoded
├── cartservice.yaml     ← image tag hardcoded
└── ...                  ← 12 separate files, all hardcoded
```

To update the frontend image you edit `frontend.yaml` directly. To deploy staging vs production with different settings, you need two complete sets of files. Every change touches multiple files.

**With Helm:**
```
online-boutique/
├── Chart.yaml           ← chart metadata
├── values.yaml          ← single file controls everything
└── templates/           ← parameterised manifests
    ├── frontend.yaml
    └── ...
```

One chart. One `values.yaml`. Helm fills in the variables and produces plain Kubernetes YAML.

## Helm Chart Structure

### Chart.yaml

Metadata about the chart — name, version, description:

```yaml
apiVersion: v2
name: onlineboutique
description: A Helm chart for Kubernetes for Online Boutique
type: application
version: 0.10.5        # chart version — increment when chart structure changes
appVersion: "v0.10.5"  # application version being deployed
```

`version` and `appVersion` are separate:
- `version` — the version of the Helm chart itself (the packaging)
- `appVersion` — the version of the application the chart deploys

### values.yaml

The configuration file. Every `{{ .Values.something }}` in a template is filled from here:

```yaml
images:
  repository: us-central1-docker.pkg.dev/google-samples/microservices-demo
  tag: ""              # empty = use appVersion from Chart.yaml

frontend:
  create: true
  name: frontend
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 64Mi
```

This is the file Jenkins writes to after every build:
```yaml
images:
  repository: 123456789.dkr.ecr.eu-central-1.amazonaws.com/cloudcommerce
  tag: "abc123f"       # ← Jenkins writes the new git commit sha here
```

### templates/

Kubernetes manifests with `{{ }}` placeholders filled from `values.yaml`:

```yaml
# templates/frontend.yaml
spec:
  containers:
  - name: server
    image: {{ .Values.images.repository }}/frontend:{{ .Values.images.tag | default .Chart.AppVersion }}
    resources:
      requests:
        cpu: {{ .Values.frontend.resources.requests.cpu }}
        memory: {{ .Values.frontend.resources.requests.memory }}
```

Helm renders this at deploy time by substituting values — the cluster receives plain Kubernetes YAML with all variables resolved.

## Helm Template Syntax

| Syntax | Meaning |
|--------|---------|
| `{{ .Values.frontend.name }}` | Value from values.yaml |
| `{{ .Chart.AppVersion }}` | Value from Chart.yaml |
| `{{ .Release.Name }}` | The helm release name (set at install time) |
| `{{- if .Values.frontend.create }}` | Conditional block |
| `{{- end }}` | End of conditional or loop |
| `{{ .Values.tag \| default "latest" }}` | Value with fallback default |
| `{{- with .Values.annotations }}` | Block only if value is not empty |

## Key Helm Commands

```bash
# Validate a chart without deploying
helm lint ./online-boutique/

# Preview the rendered YAML without deploying (dry run)
helm template myrelease ./online-boutique/

# Install a chart
helm install myrelease ./online-boutique/ -n online-boutique --create-namespace

# Upgrade an existing release with new values
helm upgrade myrelease ./online-boutique/ --set images.tag=abc123f

# List all installed releases
helm list -A

# Check status of a release
helm status myrelease

# Uninstall a release
helm uninstall myrelease -n online-boutique
```

## helm lint — Validating Before Committing

`helm lint` checks a chart for errors without deploying it:

```bash
helm lint kubernetes/apps/online-boutique/
```

Output:
```
==> Linting kubernetes/apps/online-boutique/
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

- `[INFO]` — advisory, not an error (missing icon, optional fields)
- `[WARNING]` — potential problem worth reviewing
- `[ERROR]` — the chart will fail to render or deploy

**Always run lint before pushing.** A template error caught locally takes seconds to fix. The same error caught by ArgoCD means a failed sync, debugging in the UI, and a corrective commit.

## helm template — Previewing Rendered Output

`helm template` renders the chart to YAML without touching the cluster:

```bash
helm template online-boutique kubernetes/apps/online-boutique/ | head -50
```

This shows exactly what Kubernetes will receive. Useful for:
- Verifying values are substituted correctly
- Checking the final manifest before the first deploy
- Debugging unexpected template output

## Why the Chart Lives in Our Repo

In production, teams own their Helm charts. Using an upstream chart directly (pointing ArgoCD at another team's or vendor's repo) means:

- You cannot control when the chart changes
- The upstream `values.yaml` may not match your environment
- `values.yaml` must be in your repo — it is the handoff point between Jenkins and ArgoCD
- If the upstream repo goes private or changes structure, your deployment breaks

The correct approach: copy the chart into your repo, own it, modify it. The chart is infrastructure code — it belongs in version control alongside the Ansible playbooks and Terraform modules.

## Helm vs Raw Kubernetes Manifests

| | Raw Manifests | Helm |
|---|---|---|
| **Configuration** | Hardcoded in each file | Single values.yaml |
| **Multi-environment** | Duplicate files | Different values files |
| **Templating** | None | Full Go template engine |
| **Packaging** | Loose files | Versioned chart archives |
| **Rollback** | Manual kubectl | `helm rollback` |
| **Validation** | kubectl dry-run | helm lint + template |
| **GitOps integration** | Supported | Supported (ArgoCD has built-in Helm) |

## ArgoCD and Helm

ArgoCD has Helm built-in — it renders Helm charts natively without Helm being installed on the cluster. When ArgoCD syncs:

1. Pulls the chart from the Git repository
2. Runs `helm template` internally with the `values.yaml` from the same path
3. Applies the resulting Kubernetes YAML to the cluster

Helm does not need to be installed on the k3s server. It should be installed locally for `helm lint` and `helm template` during development.

## The values.yaml Lifecycle in GitOps

```
Developer commits code
         ↓
Jenkins builds Docker image → pushes to ECR
         ↓
Jenkins updates values.yaml:
  images:
    tag: "new-git-sha"
         ↓
Jenkins commits values.yaml to GitHub
         ↓
ArgoCD detects commit → renders chart with new values
         ↓
Cluster updated with new image
```

`values.yaml` is not a configuration file set once and forgotten. It is a live deployment record — every build changes it, every ArgoCD sync reads it.

## Interview Talking Points

- "I use Helm to package the Online Boutique application — templates with variables replace hardcoded manifests, and a single values.yaml controls the entire deployment"
- "values.yaml is the handoff point between Jenkins and ArgoCD — Jenkins writes the new ECR image tag to it after every build, ArgoCD reads it and deploys"
- "I always run helm lint before pushing — it catches template errors locally before ArgoCD attempts to render them against the cluster"
- "The Helm chart lives in our own repo, not pointed at Google's — we own the deployment definition, control when it changes, and can modify values.yaml without depending on an external source"
- "ArgoCD has Helm built-in and renders charts natively — Helm doesn't need to be installed on the cluster itself"
