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

## Interview Talking Points

- "k3s is a CNCF-certified Kubernetes distribution — fully compatible with upstream kubectl, Helm, and Kubernetes manifests, but packaged as a single binary and running under 512MB RAM at idle"
- "I hit a TLS SAN error when connecting kubectl to k3s remotely — the self-signed certificate only covered the private IP, not the Elastic IP. The fix was to specify `--tls-san` at install time and reinstall — TLS certificates are generated once and cannot be patched in place"
- "kubeconfig must be re-copied every time k3s is reinstalled — the certificate-authority-data changes with each new cluster, and using the old kubeconfig produces authentication errors even if the server address is correct"
- "I use k9s for day-to-day cluster navigation alongside kubectl — it shows CPU/memory per pod in real time and makes log tailing and pod inspection faster without replacing kubectl for scripted operations"
- "kubectl on Windows was installed by downloading the .exe via WSL curl — PowerShell's Invoke-WebRequest had TLS and connection issues; WSL curl is more reliable for binary downloads"
