# k3s and Kubernetes — Deep Dive

## What is Kubernetes?

Kubernetes (k8s) is an open-source container orchestration platform. Where Docker runs a single container on a single machine, Kubernetes runs many containers across many machines — scheduling them, restarting failed ones, scaling them up and down, routing traffic to them, and rolling out updates without downtime.

The core abstractions:
- **Pod** — the smallest deployable unit; one or more containers that share a network namespace
- **Deployment** — declares the desired state for a set of pods (replica count, container image, update strategy)
- **Service** — a stable network endpoint that routes traffic to pods (pods are ephemeral; Services are not)
- **Namespace** — a virtual cluster within the cluster; used to isolate workloads
- **Node** — a machine (VM or physical) that runs pods

```
Cluster
  ├── Node (EC2 instance)
  │     ├── Pod: frontend
  │     ├── Pod: cartservice
  │     └── Pod: checkoutservice
  └── Control Plane (API server, scheduler, etcd)
```

## What is k3s?

k3s is a CNCF-certified Kubernetes distribution designed for resource-constrained environments. It is fully compatible with upstream Kubernetes — every `kubectl` command, Helm chart, and manifest works identically — but stripped of components that are not needed in single-node or edge deployments.

**What k3s removes vs upstream Kubernetes:**
- Cloud provider integrations (AWS/GCP/Azure-specific controllers)
- Legacy alpha APIs
- Out-of-tree storage drivers not needed for most workloads

**What k3s includes:**
- containerd (container runtime)
- CoreDNS (cluster DNS)
- Traefik (ingress controller, replaces NGINX in many setups)
- Local Path Provisioner (persistent volumes using node local storage)
- Metrics Server (resource usage data for HPA)

**Single binary:** k3s ships as one ~100MB binary. There is no separate installer, no package manager integration, no dependency chain. Download it, run it, and you have a Kubernetes cluster.

**Resource footprint:** k3s uses under 512MB RAM at idle — suitable for a 4GB EC2 t3.medium that also needs headroom for application workloads.

## How k3s is Installed

k3s is not available via apt. The official installation method is a shell script served over HTTPS:

```bash
curl -sfL https://get.k3s.io | sh -
```

This single command:
1. Downloads the k3s binary for the current architecture
2. Installs it to `/usr/local/bin/k3s`
3. Creates a systemd service (`k3s.service`)
4. Generates TLS certificates for the cluster
5. Starts the API server and waits for the node to reach Ready state

The script accepts configuration via environment variables passed before the pipe:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san 63.184.235.88" sh -
```

`INSTALL_K3S_EXEC` passes flags directly to the k3s server process at install time.

## TLS in Kubernetes — Subject Alternative Names (SANs)

Kubernetes API communication is secured with TLS. The API server presents a self-signed certificate to every client. kubectl verifies this certificate against the cluster's certificate authority (CA) data stored in the kubeconfig file.

TLS certificates include a **Subject Alternative Names (SAN)** list — an explicit list of IP addresses and hostnames the certificate is valid for. If the client connects to an address not in the SAN list, TLS verification fails:

```
tls: failed to verify certificate: x509: certificate is valid for
10.0.1.135, 10.43.0.1, 127.0.0.1, ::1, not 63.184.235.88
```

**k3s default SANs:**
- The node's private IP (e.g., `10.0.1.135`)
- The cluster service IP (`10.43.0.1`)
- Loopback addresses (`127.0.0.1`, `::1`)

The public Elastic IP is not included by default because k3s has no way to know it — from the server's perspective, it only sees its private IP. The public IP is assigned by AWS's NAT layer.

### The `--tls-san` Flag

```bash
INSTALL_K3S_EXEC="--tls-san 63.184.235.88" sh -
```

`--tls-san` adds entries to the TLS certificate's SAN list at generation time. This must be set before installation — TLS certificates are generated once, at cluster init. There is no way to add SANs to an existing certificate without reinstalling k3s.

**Multiple SANs:** the flag can be specified multiple times:

```bash
INSTALL_K3S_EXEC="--tls-san 63.184.235.88 --tls-san mycluster.example.com" sh -
```

## kubeconfig — How kubectl Authenticates

kubeconfig is a YAML file that tells kubectl:
- Where the cluster API server is (`server: https://63.184.235.88:6443`)
- How to verify the server's TLS certificate (`certificate-authority-data`)
- What credentials to use (`client-certificate-data`, `client-key-data`)

k3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml`. The default `server` field points to `127.0.0.1` — the loopback address, valid for on-cluster access only. For remote access, replace `127.0.0.1` with the public IP:

```bash
# Copy the kubeconfig from the server
scp -i ~/.ssh/cloudcommerce-dev-key ubuntu@63.184.235.88:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Fix the server address
sed -i 's/127.0.0.1/63.184.235.88/g' ~/.kube/config
```

The `certificate-authority-data` field contains the cluster CA certificate in base64 — this is what kubectl uses to verify the server's TLS certificate. After reinstalling k3s (e.g., to fix TLS SANs), this data changes and the kubeconfig must be re-copied.

**Multiple clusters:** kubeconfig supports multiple clusters, users, and contexts in a single file. `kubectl config use-context` switches between them.

## kubectl — The Kubernetes CLI

kubectl is the universal Kubernetes CLI. It translates commands into API requests to the cluster's API server.

**Essential commands:**

```bash
# Cluster state
kubectl get nodes                   # list nodes and their status
kubectl get pods -A                 # all pods in all namespaces
kubectl get pods -n <namespace>     # pods in a specific namespace
kubectl describe pod <name>         # full detail on a pod including events

# Deploying
kubectl apply -f manifest.yaml      # apply a manifest (create or update)
kubectl delete -f manifest.yaml     # delete resources defined in a manifest

# Debugging
kubectl logs <pod-name>             # pod stdout/stderr
kubectl logs <pod-name> -f          # follow logs in real time
kubectl exec -it <pod-name> -- sh   # shell into a running container

# Cluster info
kubectl get events --sort-by=.lastTimestamp    # recent cluster events
kubectl top pods                               # CPU/memory usage per pod (requires metrics-server)
```

**Namespaces:** Kubernetes workloads are organised into namespaces. `kubectl get pods` without `-n` defaults to the `default` namespace. System components run in `kube-system`. k3s adds `kube-node-lease` and `kube-public` automatically.

## k9s — Terminal UI for Kubernetes

k9s is a terminal-based Kubernetes dashboard. It reads from kubeconfig like kubectl and provides a real-time view of cluster state without memorising kubectl syntax for every operation.

```bash
k9s --command pods   # launch directly to pods view
```

**Navigation:**
- `0` — show all namespaces
- `/` — filter by name
- `d` — describe the selected resource
- `l` — view logs for a pod
- `e` — edit a resource in place
- `ctrl+d` — delete the selected resource
- `:` — command prompt (type a resource type to navigate to it)
- `esc` — go back / cancel
- `q` — quit

k9s remembers the last view. If you navigate to an unfamiliar resource type and get stuck, launch with `k9s --command pods` to force the starting view.

**What k9s shows that kubectl does not:**
- Real-time CPU and memory usage per pod without running `kubectl top` separately
- Pod restart counts and ages at a glance
- Color-coded status (green = Running, yellow = Pending, red = Failed/CrashLoopBackOff)

## Kubernetes System Components (k3s)

After a fresh k3s install, `kubectl get pods -A` shows 7 system pods:

| Pod | Namespace | Role |
|-----|-----------|------|
| coredns | kube-system | Cluster DNS — resolves service names to IPs inside the cluster |
| metrics-server | kube-system | Collects CPU/memory usage data — required for HPA |
| traefik | kube-system | Ingress controller — routes external HTTP(S) traffic to services |
| local-path-provisioner | kube-system | Creates PersistentVolumes using node-local storage |
| svclb-traefik-* | kube-system | Service load balancer for Traefik — one pod per node |

All 7 should be in Running state before deploying any workloads.

## Installing kubectl on Windows

kubectl is a single binary (`kubectl.exe`) that needs to be on the Windows PATH.

**Methods (from most to least reliable on Windows):**

1. **WSL curl (recommended):**
   ```bash
   curl -LO "https://dl.k8s.io/release/v1.36.1/bin/windows/amd64/kubectl.exe"
   ```
   Downloads to the WSL current directory, accessible from Windows.

2. **winget:** `winget install -e --id Kubernetes.kubectl` — installs but may not add to PATH correctly; location is unreliable.

3. **PowerShell Invoke-WebRequest:** Unreliable TLS/connection handling on Windows 10; use WSL curl instead.

**Making the PATH permanent:**
```powershell
[System.Environment]::SetEnvironmentVariable(
    "PATH",
    $env:PATH + ";C:\path\to\kubectl",
    [System.EnvironmentVariableTarget]::User
)
```

This writes to the user's environment in the registry. New terminal sessions inherit it automatically. The current session needs to be restarted, or set `$env:PATH` temporarily for the current session.

## ReplicaSets — How Kubernetes Manages Rolling Updates

A **ReplicaSet** is the Kubernetes object that ensures a specific number of identical pods are always running. Every Deployment manages one or more ReplicaSets behind the scenes.

When you deploy a new image version, Kubernetes does not modify the existing pods. It:
1. Creates a **new ReplicaSet** with the new image definition
2. Scales the new RS up (starts new pods)
3. Scales the old RS down (terminates old pods)
4. Keeps old RSes around at `DESIRED=0` for rollback history

```
kubectl get rs -n online-boutique

NAME                    DESIRED   CURRENT   READY   AGE
adservice-5c945f559b    0         0         0       143m   ← old (kept for rollback)
adservice-75564965fc    0         0         0       78m    ← older failed attempt
adservice-7b7f5f9696    1         1         1       19m    ← current live RS
```

**Rollback uses the old RS** — `kubectl rollout undo` simply scales the previous RS back to 1 and scales the current one to 0. It does not need the old pods — it needs the old RS definition (which remembers the old image tag). Kubernetes keeps up to 10 RS revisions by default.

## Rolling Update Deadlock — Single Node Resource Pressure

On a single-node cluster with tight resources, rolling updates can deadlock:

**The deadlock:**
1. Old pods are running and consuming CPU/memory reservations
2. New pods are created but stuck `Pending` — cannot be scheduled (no room)
3. Old pods only terminate when new pods reach `Running`
4. New pods can never reach `Running` because old pods won't free resources
5. The cluster is stuck

**How to diagnose:**
```bash
kubectl describe node | grep -A 5 "Allocated resources"
# → cpu: 88% requested, 141% limits — overcommitted
```

**Solutions:**

| Solution | How | Trade-off |
|----------|-----|-----------|
| `Recreate` strategy | Kill all old pods first, then create new | Brief downtime |
| `maxUnavailable: 1, maxSurge: 0` | Kill one old pod before creating new one | No extra resource usage |
| Bigger node | More CPU/RAM on EC2 | Higher cost |

**`Recreate` does NOT break rollback.** Rollback lives in the ReplicaSet definition, not the pods. Old RS stays in etcd regardless of strategy.

## Deployment Strategies

**RollingUpdate (default):**
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%         # how many extra pods during update
    maxUnavailable: 25%   # how many pods can be down during update
```
Zero downtime if resources allow. Can deadlock on a tight single node.

**Recreate:**
```yaml
strategy:
  type: Recreate
```
All old pods terminated before any new pods start. Brief downtime. No resource surge. Correct choice for single-node development clusters.

## Service Types — How Traffic Reaches Pods

Pods are ephemeral — they come and go. Services are stable endpoints that route traffic to whatever pods are currently running.

| Type | Who can reach it | How |
|------|-----------------|-----|
| `ClusterIP` | Only other pods inside the cluster | Internal DNS name |
| `NodePort` | Anyone with the node's IP + port | `http://IP:30000-32767` |
| `LoadBalancer` | Public internet | Cloud provider assigns external IP |

**In k3s specifically:** LoadBalancer services are handled by **ServiceLB (Klipper)** — k3s's built-in load balancer. It exposes the service on the node's public IP. k3s also ships with **Traefik** as an ingress controller, which already holds port 80 and 443. When you create a LoadBalancer service on port 80, Traefik picks it up and routes it automatically.

## Port-Forward — Development Tool, Not Production Access

```bash
kubectl port-forward svc/frontend 8080:80 -n online-boutique
```

This tunnels a local port to a pod through the Kubernetes API server. It:
- Only works while the terminal is open and the command is running
- Exits when you close the terminal or press Ctrl+C
- Is not a service, not a load balancer, not persistent
- Is the correct tool for temporary debugging access

**For permanent access:** use a `LoadBalancer` service or an `Ingress` resource. In this project, setting `externalService: true` in `values.yaml` creates a LoadBalancer service that Traefik picks up — the site then lives permanently at the node's public Elastic IP with no terminal required.

## ECR Authentication for containerd (registries.yaml)

k3s uses `containerd` as its container runtime — not Docker. Docker and containerd are both container runtimes, but they have separate credential systems.

**The problem:** Even though the k3s EC2 instance has an IAM role that allows ECR pulls, containerd does not automatically use IAM credentials. Without explicit configuration, every image pull from ECR returns `no basic auth credentials`.

**The fix:** Write a `registries.yaml` file to `/etc/rancher/k3s/registries.yaml` before k3s starts:

```yaml
configs:
  "927311782753.dkr.ecr.eu-central-1.amazonaws.com":
    auth:
      username: "AWS"
      password: "<ecr-token>"
```

This file is read by containerd at startup. The ECR token is fetched from the local machine during the Ansible playbook run using `aws ecr get-login-password`, then written to the server. k3s must be restarted to pick up the new configuration.

**ECR tokens expire after 12 hours.** The Ansible playbook approach means the token is refreshed every time the playbook runs. For a production setup, this would be automated via a CronJob or IAM-based credential provider.

**imagePullSecrets vs registries.yaml:**
- `imagePullSecrets` is a Kubernetes-level credential — attached to a pod or ServiceAccount
- `registries.yaml` is a containerd-level credential — applies to all pulls on the node
- `registries.yaml` is the correct permanent solution; `imagePullSecrets` works but expires every 12 hours and must be regenerated

## k9s — Terminal UI for Kubernetes

k9s is a terminal-based UI built on top of kubectl. It provides real-time cluster navigation without memorising full kubectl syntax for every operation.

```bash
k9s --command pods    # open directly to pods view
```

**What k9s shows that kubectl doesn't by default:**
- CPU and memory usage per pod in real time
- Pod age, restart count, and status in a single view
- Log tailing with `l` key — no need to remember pod names
- Shell access into a pod with `s` key
- Resource deletion with `ctrl+d`

**k9s vs kubectl:** k9s is for exploration and debugging. kubectl is for scripted operations, CI/CD, and anything that needs to be repeatable. Both are used — k9s does not replace kubectl, it complements it.

## The Kubernetes Debugging Framework — Outside-In Approach

Every Kubernetes problem can be solved with the same approach: start at the highest level, drill down only when you know where the problem is. Never jump to conclusions.

### The Golden Rule
**Run the wide scan first. Then narrow down.**

---

### Layer 1 — Can I even reach the cluster?

```bash
kubectl get nodes
```

| Result | Meaning | Fix |
|---|---|---|
| `Ready` | All good — move to Layer 2 | — |
| `NotReady` | Node is unhealthy | Check node resources, restart k3s |
| TLS handshake timeout | Node is overloaded or API server is down | Reboot EC2 from AWS Console |
| x509 certificate error | Wrong kubeconfig or missing TLS SAN | `echo $KUBECONFIG` → copy fresh kubeconfig |
| Connection refused | k3s service crashed | SSH in → `sudo systemctl restart k3s` |

---

### Layer 2 — What is broken? (Run these two together — always)

```bash
kubectl get pods -A                                          # WHAT is broken (status column)
kubectl get events -A --sort-by=.lastTimestamp | tail -30   # WHY it broke (reason + message)
```

**`kubectl get events` is often the fastest path to the answer.** It shows every scheduling decision, image pull attempt, crash, and resource failure across the whole cluster — sorted by time. Run it before `kubectl describe`, not after.

**Read the pod STATUS column:**

| Status | Plain English | Where to look next |
|---|---|---|
| `Pending` | Can't find a place to run | Node resources / HostPort conflict |
| `CrashLoopBackOff` | Starting, crashing, repeating | `kubectl logs --previous` |
| `ImagePullBackOff` / `ErrImagePull` | Can't get the container image | ECR token / IAM role / wrong tag |
| `OOMKilled` | Memory limit exceeded, OS killed it | Increase memory limit |
| `Error` | Crashed and stopped retrying | `kubectl logs` |
| `Running` but 0/1 Ready | Container running but health check failing | Readiness probe / app not ready yet |
| `Terminating` stuck | Pod won't shut down | `kubectl delete pod --force --grace-period=0` |

---

### Layer 3 — Why is it broken? (Drill into the problem)

#### Pod problems:
```bash
# Full detail on a specific pod — ALWAYS read the Events section at the bottom
kubectl describe pod <pod-name> -n <namespace>

# What did the application say before it crashed?
kubectl logs <pod-name> -n <namespace> --tail=50
kubectl logs <pod-name> -n <namespace> --previous   # ← essential for CrashLoopBackOff
```

#### Scheduling / Pending problems:
```bash
# Is the node out of resources?
kubectl describe node | grep -A 8 "Allocated resources"
# CPU/Memory Requests near 100% = scheduling deadlock even if actual usage is low

# What exact reason is stopping the pod from scheduling?
kubectl describe pod <pod-name> -n <namespace>
# Events will show: Insufficient cpu / Insufficient memory / HostPort conflict
```

#### Image pull problems:
```bash
kubectl describe pod <pod-name> -n <namespace>
# Read the Events section for the exact error:
# "no basic auth credentials"   → ECR token expired → refresh token
# "manifest unknown"            → wrong image tag → check values.yaml
# "repository does not exist"   → wrong ECR repo name
# "pull access denied"          → IAM role missing ECR permissions
```

#### Networking problems (app runs but isn't reachable):
```bash
kubectl get svc -n <namespace>           # does the service exist? what type?
kubectl get ingress -n <namespace>       # does the ingress rule exist?

# Test connectivity from inside the cluster (most reliable)
kubectl exec -it <any-running-pod> -n <namespace> -- wget -qO- http://<service>.<namespace>.svc.cluster.local:<port>
# "ready" or HTML response = network is fine, problem is elsewhere
# "connection refused" = service exists but pod isn't listening on that port
# "no such host" = service name wrong or DNS issue
```

#### Resource / performance problems:
```bash
kubectl top pods -A            # actual real-time CPU and memory usage
kubectl top nodes              # node-level actual usage
kubectl describe node | grep -A 8 "Allocated resources"
# Requests = what is RESERVED for scheduling (affects pod placement)
# Limits = maximum a pod is ALLOWED to use
# High Requests + Low actual usage = over-provisioned → reduce requests
```

---

### Layer 4 — Confirm the fix worked

```bash
kubectl get pods -A                                        # everything Running?
kubectl get events -A --sort-by=.lastTimestamp | tail -10  # no new Warnings?
curl -I http://<your-ip>                                   # site actually responding?
```

---

### The Complete Debugging Mind Map

```
SOMETHING IS WRONG
│
├── Can't reach cluster at all?
│   └── kubectl get nodes → timeout / error
│       ├── SSH also fails?   → Node is dead → Reboot from AWS Console
│       ├── x509 error?       → Check $KUBECONFIG → copy fresh kubeconfig
│       └── Connection refused → sudo systemctl restart k3s
│
└── Cluster reachable — what's broken?
    └── kubectl get pods -A  +  kubectl get events -A
        │
        ├── PENDING
        │   └── kubectl describe pod → Events section
        │       ├── Insufficient cpu/memory → reduce requests or resize node
        │       ├── HostPort conflict       → another pod owns that port
        │       └── No nodes available      → taint or node selector mismatch
        │
        ├── CRASHLOOPBACKOFF
        │   └── kubectl logs --previous → read the actual crash message
        │       ├── OOMKilled           → increase memory limit
        │       ├── Config/secret error → check mounted ConfigMaps/Secrets
        │       └── Two defaults        → provisioning conflict (isDefault: true)
        │
        ├── IMAGEPULLBACKOFF
        │   └── kubectl describe pod → Events → read the exact error
        │       ├── no basic auth     → ECR token expired → refresh/cron job
        │       ├── manifest unknown  → wrong image tag → check values.yaml
        │       └── pull access denied → IAM role missing ECR permission
        │
        ├── RUNNING but site is down
        │   ├── kubectl get svc     → service exists? right type?
        │   ├── kubectl get ingress → routing rule exists?
        │   └── exec into pod       → test connectivity with wget/curl
        │
        └── RUNNING and site is up but ALERTS firing
            ├── kubectl get events -A → any Warnings?
            ├── Check AlertManager UI → read exact alert name
            └── Is it a k3s false positive? → silence it (see below)
```

---

## k3s-Specific Quirks — What Bites You That Doesn't Exist on EKS

These are issues that only occur on k3s and will not appear in standard Kubernetes documentation. Every one of these was hit in this project:

### 1 — k3s False Positive Alerts

`kube-prometheus-stack` ships with alert rules written for upstream Kubernetes. k3s combines scheduler, controller-manager, and kube-proxy into a **single binary** — there are no separate processes with individual metrics endpoints.

Result: Prometheus fires `KubeSchedulerDown`, `KubeControllerManagerDown`, `KubeProxyDown` as **critical alerts permanently** on any k3s cluster.

**Fix — silence them in AlertManager:**
```yaml
route:
  routes:
    - receiver: 'null'
      matchers:
        - alertname =~ "Watchdog|InfoInhibitor|KubeSchedulerDown|KubeControllerManagerDown|KubeProxyDown|etcdInsufficientMembers"
```

**Rule:** On k3s, always silence these four alerts on first setup. They are not real incidents.

---

### 2 — Traefik Owns Port 80 — LoadBalancer Services Conflict

k3s installs Traefik by default as the ingress controller. Traefik's ServiceLB pod (`svclb-traefik`) binds **HostPort 80 and 443** on the node.

If you create a `LoadBalancer` service on port 80, k3s's Klipper ServiceLB creates a DaemonSet pod that also tries to bind HostPort 80 — and gets stuck `Pending` forever because Traefik already owns it.

```
svclb-traefik-xxx          → Running  ← owns HostPort 80
svclb-frontend-external-xxx → Pending  ← can't start, port taken
```

**The site works** because Traefik's Ingress routes traffic correctly. The LoadBalancer is redundant.

**Fix:** Use `externalService: false` and expose via Traefik Ingress instead. One Ingress rule, one port owner, no conflicts:

```yaml
frontend:
  externalService: false   # use Ingress, not LoadBalancer
```

---

### 3 — ECR Token Expiry (containerd doesn't auto-refresh)

containerd (k3s's runtime) does not use IAM roles automatically. The ECR token must be written explicitly to `/etc/rancher/k3s/registries.yaml`. ECR tokens expire after **12 hours**.

**Symptom:** Pods that were Running keep running (cached images). New pods in a rolling update hit `ImagePullBackOff` with "no basic auth credentials".

**Fix:** Cron job that refreshes every 6 hours using the IAM instance profile:
```bash
# /usr/local/bin/refresh-ecr-token.sh
TOKEN=$(aws ecr get-login-password --region eu-central-1)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
cat > /etc/rancher/k3s/registries.yaml << EOF
configs:
  "${ACCOUNT}.dkr.ecr.eu-central-1.amazonaws.com":
    auth:
      username: "AWS"
      password: "${TOKEN}"
EOF
systemctl restart k3s

# Cron (root crontab)
0 */6 * * * /usr/local/bin/refresh-ecr-token.sh
```

---

### 4 — kubeconfig Permissions Reset After Reboot

k3s regenerates `/etc/rancher/k3s/k3s.yaml` on every boot with root-only permissions (0600). The `ubuntu` user cannot read it.

**Symptom:** `kubectl get pods` returns permission denied after any reboot.

**Fix:**
```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

**Permanent fix** — add `--write-kubeconfig-mode 644` to the k3s install command so permissions survive reboots.

---

### 5 — TLS Certificate Doesn't Include Public IP

k3s generates its TLS certificate at install time. By default it only includes the node's private IP. Connecting kubectl from outside the VPC using the public Elastic IP fails with an x509 error.

**Fix:** Pass `--tls-san <public-ip>` at install time. Cannot be added after — requires reinstall.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san 63.184.235.88" sh -
```

---

### 6 — Ansible `creates:` Guard on k3s Install Task

Without a guard, re-running the k3s Ansible playbook reinstalls k3s from scratch — wiping the entire cluster, all pods, all ArgoCD state.

**Fix — add `args.creates:` to make the install task idempotent:**
```yaml
- name: Install k3s
  shell: curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san 63.184.235.88" sh -
  args:
    creates: /usr/local/bin/k3s   # skip if binary already exists
```

---

### Quick Reference — k3s Quirks at a Glance

| Quirk | Symptom | Fix |
|---|---|---|
| Single binary (no separate scheduler/controller/proxy) | KubeSchedulerDown critical alerts permanently | Silence in AlertManager null route |
| Traefik owns port 80 | LoadBalancer pod stuck Pending forever | Use Ingress, set `externalService: false` |
| containerd needs explicit ECR credentials | ImagePullBackOff after 12 hours on rolling update | Cron job refreshing ECR token every 6h |
| kubeconfig root-only permissions | kubectl permission denied after reboot | `chmod 644 /etc/rancher/k3s/k3s.yaml` |
| TLS cert generated at install time | x509 error connecting remotely | Reinstall with `--tls-san <public-ip>` |
| No idempotency guard on install task | Ansible playbook wipes entire cluster | `args.creates: /usr/local/bin/k3s` |

---

## Interview Talking Points

### Factual Points (what to say about the technology)

- "k3s is a CNCF-certified Kubernetes distribution — fully compatible with upstream kubectl, Helm, and Kubernetes manifests, but packaged as a single binary and running under 512MB RAM at idle"
- "k3s combines the scheduler, controller-manager, and kube-proxy into a single binary — this means standard Prometheus alert rules for those components fire as false positives on k3s and need to be silenced"
- "I hit a TLS SAN error when connecting kubectl to k3s remotely — the self-signed certificate only covered the private IP, not the Elastic IP. The fix was `--tls-san` at install time — TLS certificates are generated once and cannot be patched in place"
- "kubeconfig must be re-copied every time k3s is reinstalled — the certificate-authority-data changes with each new cluster, and using the old kubeconfig produces authentication errors even if the server address is correct"
- "containerd does not automatically use IAM credentials for ECR pulls — it needs explicit registry configuration in `/etc/rancher/k3s/registries.yaml`. ECR tokens expire every 12 hours, so a cron job is required to keep them fresh"
- "Port-forward is a development debugging tool, not a production access method — it tunnels a local port through the API server and exits when the terminal closes"
- "ReplicaSets are what Kubernetes uses for rolling updates — each new deployment creates a new RS, scales it up, and scales the old RS down. Old RSes stay at DESIRED=0 for rollback history. Rollback is just scaling the previous RS back up"
- "CPU requests and CPU usage are completely different things — requests are what Kubernetes reserves for scheduling decisions, usage is what's actually consumed. A node at 100% requests with 15% actual usage will refuse to schedule new pods"

---

### Scenario Questions (how to answer "what would you do if...")

**"A pod is stuck in CrashLoopBackOff — walk me through your approach"**
> "First I run `kubectl get events -A --sort-by=.lastTimestamp` to see if there's an immediate clue. Then `kubectl describe pod` to read the Events section. Then `kubectl logs --previous` — the `--previous` flag is essential because the current container has already crashed and restarted; I need the logs from the run before that. 99% of the time the actual error message is there."

**"Deployments are stuck — nothing is rolling out"**
> "I'd check node resource allocation first — `kubectl describe node` to see if CPU or memory requests are at 100%. If they are, Kubernetes can't place the new pod alongside the old one during the rolling update. Old pods won't terminate until new pods are Running, and new pods can't start because there's no room. The fix is either reducing requests to match actual observed usage from Prometheus metrics, or using Recreate strategy on single-node clusters."

**"The site is down but all pods show Running"**
> "`Running` means the container is alive — it doesn't mean it's healthy or reachable. I'd check the Service with `kubectl get svc`, then the Ingress with `kubectl get ingress`, then shell into a pod and test the connection directly with curl or wget to the service's cluster DNS name. That isolates whether the problem is the application, the Service layer, or the Ingress layer."

**"How do you know if a node is about to run out of memory?"**
> "Two separate commands — `kubectl top nodes` for actual real-time usage, and `kubectl describe node` for requests which are what's reserved for scheduling. If actual usage is at 85%+ you're approaching OOM kills. If requests are at 100% you'll get scheduling failures even if actual usage is low. Both matter for different reasons and they tell different stories."

**"You're getting critical alerts that Kubernetes components are down — how do you respond?"**
> "First I check if the cluster is actually healthy — `kubectl get nodes` and `kubectl get pods -A`. If everything is Running and the site is up, these are likely false positives. On k3s specifically, alerts like `KubeSchedulerDown` and `KubeControllerManagerDown` are permanent false positives because k3s combines those components into a single binary without the standard Prometheus scrape endpoints. The correct response is to silence them via AlertManager routing, not to treat them as real incidents."

**"An ImagePullBackOff appeared after a rolling update — what do you check?"**
> "`kubectl describe pod` to read the exact error from the Events section. Common causes: ECR token expired after 12 hours — the cron job should catch this but a one-time fix is refreshing the token and restarting k3s. Wrong image tag — Jenkins may have written a tag that doesn't exist in ECR yet. IAM role missing permissions — though this would fail on every pull, not just after 12 hours."

**"How do you approach debugging Kubernetes issues in general?"**
> "Outside-in. Start with `kubectl get nodes` to confirm the cluster is reachable. Then `kubectl get pods -A` and `kubectl get events -A --sort-by=.lastTimestamp` together — events is often faster than describe because it shows the reason across all namespaces in one view. Once I know which pod and what category of problem, I drill down with describe and logs. I never jump straight to logs without knowing which pod is actually failing first."
