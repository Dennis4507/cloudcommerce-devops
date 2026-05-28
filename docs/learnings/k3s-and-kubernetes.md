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

## Interview Talking Points

- "k3s is a CNCF-certified Kubernetes distribution — fully compatible with upstream kubectl, Helm, and Kubernetes manifests, but packaged as a single binary and running under 512MB RAM at idle"
- "I hit a TLS SAN error when connecting kubectl to k3s remotely — the self-signed certificate only covered the private IP, not the Elastic IP. The fix was to specify `--tls-san` at install time and reinstall — TLS certificates are generated once and cannot be patched in place"
- "kubeconfig must be re-copied every time k3s is reinstalled — the certificate-authority-data changes with each new cluster, and using the old kubeconfig produces authentication errors even if the server address is correct"
- "I use k9s for day-to-day cluster navigation alongside kubectl — it shows CPU/memory per pod in real time and makes log tailing and pod inspection faster without replacing kubectl for scripted operations"
- "kubectl on Windows was installed by downloading the .exe via WSL curl — PowerShell's Invoke-WebRequest had TLS and connection issues; WSL curl is more reliable for binary downloads"
- "ReplicaSets are what Kubernetes uses to manage rolling updates — each new deployment creates a new RS and scales the old one down. Old RSes are kept at DESIRED=0 for rollback history. Rollback is just scaling the previous RS back up"
- "We hit a rolling update deadlock on a single-node cluster — old ImagePullBackOff pods were consuming resource reservations, new pods couldn't schedule, and old pods wouldn't terminate until new ones were Ready. The solution is Recreate strategy on resource-constrained single nodes"
- "Recreate strategy does not break rollback — rollback lives in the ReplicaSet definition stored in etcd, not in the running pods"
- "containerd does not automatically use IAM credentials for ECR pulls — unlike Docker, containerd needs explicit registry configuration in /etc/rancher/k3s/registries.yaml. Without it, even a correctly configured IAM role produces 'no basic auth credentials'"
- "Port-forward is a development debugging tool — it tunnels a local port through the Kubernetes API server and exits when the terminal closes. For permanent external access, LoadBalancer services or Ingress resources are the correct approach"
- "In k3s, LoadBalancer services are handled by Klipper ServiceLB and Traefik — a LoadBalancer service on port 80 is automatically picked up by Traefik and exposed on the node's public IP"
