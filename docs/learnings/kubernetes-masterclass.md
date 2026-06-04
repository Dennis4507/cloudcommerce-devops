# Kubernetes Masterclass — From Zero to Expert

Everything you need to deeply understand Kubernetes. Written in plain language first, then technical depth. Every concept connected to the real project you built.

**How to use this file:** Read it top to bottom once to build the mental model. Then use it as a reference — search for any concept you encounter and the explanation is here.

---

## Part 1 — The One Idea That Explains Everything

Before anything else. This is the foundation. If you understand this, everything else makes sense.

### Kubernetes is a reconciliation engine

Kubernetes does one thing, over and over, forever:

```
Look at what you WANT  →  Look at what EXISTS  →  Close the gap
```

That's it. Every feature, every component, every design decision in Kubernetes comes back to this loop.

You write a file that says "I want 3 copies of this application running." Kubernetes reads it, counts how many are actually running, and if the number doesn't match, it takes action. If you have 2, it starts 1 more. If someone deletes one, it starts a replacement. If you change the number to 5, it starts 2 more. If you change it to 0, it stops them all.

This loop never stops. It runs every few seconds. That is what makes Kubernetes self-healing.

**In your project:** When you set `externalService: false` and pushed to Git, ArgoCD ran this same loop — it compared what Git said should exist against what was in the cluster, found the difference, and deleted the LoadBalancer service. You didn't tell Kubernetes to delete it. You told it what the desired state was, and it figured out the action.

---

## Part 2 — The Architecture (What the Pieces Are)

A Kubernetes cluster has two kinds of machines:

```
┌─────────────────────────────────────────────────────────────────┐
│                        CONTROL PLANE                            │
│  The brain. Makes all decisions. Manages the cluster.           │
│                                                                 │
│  ┌─────────┐  ┌────────────┐  ┌───────────┐  ┌─────────────┐  │
│  │  etcd   │  │ API Server │  │ Scheduler │  │  Controller │  │
│  │         │  │            │  │           │  │  Manager    │  │
│  └─────────┘  └────────────┘  └───────────┘  └─────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         ↕ (control plane talks to worker nodes)
┌─────────────────────────────────────────────────────────────────┐
│                        WORKER NODE(S)                           │
│  Where your application actually runs.                          │
│                                                                 │
│  ┌─────────┐  ┌────────────────┐  ┌────────────────────────┐   │
│  │ kubelet │  │   containerd   │  │  kube-proxy / CNI      │   │
│  │         │  │  (runs pods)   │  │  (networking)          │   │
│  └─────────┘  └────────────────┘  └────────────────────────┘   │
│                                                                 │
│  Pod: frontend    Pod: cartservice    Pod: prometheus           │
└─────────────────────────────────────────────────────────────────┘
```

**In your project:** You have one EC2 instance (t3.large) running BOTH the control plane AND the worker node. This is k3s — it combines everything into one machine. In production (EKS, GKE), these are always separate. AWS manages the control plane for you so you never touch it.

---

### The Four Control Plane Components

#### 1 — etcd (the database)

Think of etcd as the cluster's memory. Everything Kubernetes knows about the cluster is stored here — every Deployment, every Service, every Secret, every Pod definition. It is a key-value database designed to be fast, reliable, and consistent.

**The critical fact:** etcd is the single source of truth. The API server never stores anything itself — it always reads from and writes to etcd. If etcd is lost, the cluster has no memory of what should exist. This is why backing up etcd is a non-negotiable production requirement.

**What's in it:** Every object you've ever `kubectl apply`-d. Your online-boutique Deployment, your ArgoCD Applications, your Prometheus ServiceMonitors — all of it is a record in etcd.

---

#### 2 — API Server (the front door)

Every single thing that communicates with Kubernetes goes through the API server. kubectl talks to it. ArgoCD talks to it. The scheduler talks to it. The kubelet on worker nodes talks to it. Nothing talks to etcd directly — only the API server does.

The API server is an HTTP server (HTTPS, port 6443). When you run `kubectl get pods`, kubectl sends a GET request to the API server. The API server checks your identity (authentication), checks your permissions (authorisation), then reads from etcd and returns the result.

**Why this matters:** This is why `--server https://63.184.235.88:6443` in your kubeconfig is the only address kubectl needs. Everything goes through that one port.

---

#### 3 — Scheduler (where should this pod run?)

The scheduler watches for pods that have no node assigned. When it finds one, it runs through a list of rules to decide which node to place it on.

**Step 1 — Filter (eliminate unsuitable nodes):**
- Does the node have enough CPU and memory to satisfy the pod's requests?
- Does the node have a taint the pod doesn't tolerate?
- Does the pod have a nodeSelector that this node doesn't match?

**Step 2 — Score (rank the remaining nodes):**
- Which node has the most available resources?
- Which node already runs the fewest pods of this type? (spread them out)
- Which node is preferred by the pod's affinity rules?

The node with the highest score gets the pod. That assignment is written to etcd. The kubelet on that node picks it up.

**What you've experienced:** When CPU requests were at 100%, the scheduler ran Step 1, filtered out your only node (insufficient CPU), and found no node passed the filter. Result: pod stays Pending forever. The scheduler didn't fail — it made the correct decision with the resources available.

---

#### 4 — Controller Manager (the reconciliation engine)

This is where the reconciliation loops live. The controller manager runs dozens of controllers simultaneously, each watching one type of resource:

- **Deployment controller** — watches Deployments, creates/updates ReplicaSets
- **ReplicaSet controller** — watches ReplicaSets, creates/deletes Pods
- **Node controller** — watches Node health, marks pods for rescheduling if a node goes down
- **Job controller** — watches Jobs, creates Pods to run them to completion
- **Endpoints controller** — keeps Service endpoint lists up to date

Each controller is an infinite loop:
```
while true:
    desired = read desired state from etcd
    actual = observe current cluster state
    if desired != actual:
        take action
    sleep(a few seconds)
```

**In your project:** When ArgoCD deleted the `frontend-external` Service, the Endpoints controller noticed the Service was gone and cleaned up its endpoint records. The ServiceLB controller noticed the LoadBalancer Service was gone and deleted the `svclb-frontend-external` pod. All of this happened automatically through controller loops — you just changed one value in a YAML file.

---

### The Worker Node Components

#### kubelet (the node agent)

Every worker node runs a kubelet. The kubelet watches the API server for pods assigned to its node. When a pod is assigned, the kubelet:
1. Tells the container runtime (containerd) to pull the images
2. Creates the container
3. Monitors it and reports health back to the API server
4. Restarts it if the liveness probe fails

The kubelet is why pods restart when they crash — the kubelet notices the container exited and starts it again.

---

#### containerd (the runtime)

containerd is the program that actually runs containers. It pulls images, manages their storage, starts and stops them. Docker used to do this role but Kubernetes deprecated Docker in 2020 — not because Docker is bad, but because the direct container runtime interface (CRI) is more efficient.

**In your project:** containerd is why `registries.yaml` matters. containerd manages all image pulls. When the ECR token expired, containerd was the one receiving the "unauthorized" response from AWS and reporting `ImagePullBackOff`. Docker would have used its own credential store; containerd uses `registries.yaml`.

---

#### kube-proxy / CNI (the networking layer)

Two separate concerns:
- **kube-proxy** maintains the network rules that make Services work (on k3s, Traefik + ServiceLB handle this)
- **CNI (Container Network Interface)** gives each pod a unique IP address and makes pod-to-pod communication work

Every pod in your cluster has its own IP (you can see them in k9s — `10.42.0.xxx`). These are cluster-internal IPs. Pods can communicate with each other using these IPs directly, or more reliably via Service DNS names.

---

## Part 3 — The Core Objects

These are the building blocks you work with every day.

---

### Pods — The Smallest Unit

A pod is one or more containers that share:
- A network (same IP address, same ports)
- Storage volumes
- The same lifecycle (start together, stop together)

**The most important thing about pods:** They are ephemeral. They are not designed to be permanent. When a pod crashes, Kubernetes doesn't repair it — it discards it and creates a new one. The new pod has a different name, a different IP, possibly a different node.

This is why you never connect to a pod directly. The pod you connect to today might not exist tomorrow. Services exist to solve this problem.

```yaml
# The simplest possible pod (you'd never use this directly — use a Deployment)
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    ports:
    - containerPort: 80
```

**In your project:** Your `frontend` pod has had multiple incarnations. Every rolling update created a new pod with a new name and IP. The frontend service always points to the current pod because it uses labels, not pod names.

---

### Deployments — Managing Pods at Scale

A Deployment is a declaration of desired state for a set of pods. You don't manage pods directly — you tell the Deployment what you want and it manages the pods for you.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 2                    # I want 2 pods running
  selector:
    matchLabels:
      app: frontend              # manage pods with this label
  template:                      # the pod template
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: frontend
        image: my-ecr/frontend:abc123
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
```

**What Deployments give you:**
- **Self-healing** — if a pod crashes, the ReplicaSet controller creates a replacement
- **Rolling updates** — change the image tag, pods update one by one without downtime
- **Rollback** — every update creates a new ReplicaSet; old ones are kept for rollback
- **Scaling** — change `replicas: 2` to `replicas: 5`, three new pods appear

---

### ReplicaSets — What Deployments Use Internally

You rarely create ReplicaSets directly. Deployments create and manage them. Each version of a Deployment gets its own ReplicaSet:

```
Deployment: frontend
  ├── ReplicaSet: frontend-abc123 (image v1) → DESIRED=0 (kept for rollback)
  ├── ReplicaSet: frontend-def456 (image v2) → DESIRED=0 (kept for rollback)
  └── ReplicaSet: frontend-ghi789 (image v3) → DESIRED=2 (current)
```

**Rolling update flow:**
1. You change the image from v3 to v4
2. Deployment controller creates new ReplicaSet for v4
3. New RS scales up: starts 1 new pod
4. Once new pod is Running, old RS scales down: stops 1 old pod
5. Repeat until all pods are running v4
6. Old RS stays at DESIRED=0 (available for rollback)

**Rollback:**
```bash
kubectl rollout undo deployment/frontend -n online-boutique
# Deployment controller scales old RS back up, scales current RS down
# No new image pull needed — old RS definition is already in etcd
```

---

### Services — Stable Network Endpoints

Pods are ephemeral and their IPs change. Services are permanent. A Service has a stable IP and DNS name that never changes, and it routes traffic to whatever pods are currently running that match its selector.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: online-boutique
spec:
  selector:
    app: frontend               # route to pods with this label
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP               # only reachable inside the cluster
```

**How it works internally:**
1. The Endpoints controller watches for pods matching `app: frontend`
2. It builds a list of their IPs and ports
3. kube-proxy (or Traefik) updates routing rules to send traffic to those IPs
4. When you hit `frontend:80`, traffic is load-balanced across all matching pods

**The DNS magic:** Every Service gets a DNS entry automatically:
```
<service-name>.<namespace>.svc.cluster.local
frontend.online-boutique.svc.cluster.local → 10.43.x.x
```

This is how your microservices find each other. The `checkoutservice` talks to `cartservice` using the DNS name, not the IP. If the cartservice pod dies and gets a new IP, the DNS name stays the same.

---

### The Three Service Types

```
ClusterIP     → only reachable inside the cluster
                 used for service-to-service communication
                 example: cartservice talking to Redis

NodePort      → reachable from outside on a fixed port (30000-32767)
                 used for dev/testing access without a load balancer
                 example: kubectl port-forward is basically this

LoadBalancer  → requests a real external load balancer from the cloud provider
                 on AWS: creates an ELB with a public IP
                 on k3s: Klipper ServiceLB binds the service to the node's IP
                 example: your frontend-external service (which caused the HostPort conflict)
```

---

### Labels and Selectors — The Glue of Everything

Labels are key-value pairs attached to any Kubernetes object. Selectors find objects by their labels.

```yaml
# Pod has a label
metadata:
  labels:
    app: frontend
    version: "v2"
    environment: production

# Service selector finds pods with this label
spec:
  selector:
    app: frontend     # matches any pod with app=frontend, regardless of version
```

**Why labels matter:** Almost nothing in Kubernetes uses names to find things — everything uses labels. A Service finds its pods by label. A Deployment manages its ReplicaSets by label. NetworkPolicies select their targets by label. AlertManager routes alerts by labels. Prometheus scrapes pods by labels.

**Labels vs Annotations:**
- **Labels** — used for selection/querying (must match exactly, kept small)
- **Annotations** — used for metadata/tooling (can be large, not used for selection)

---

### ConfigMaps — Injecting Configuration

A ConfigMap holds non-sensitive configuration data. Pods read it either as environment variables or as mounted files.

```yaml
# Create the ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  DATABASE_URL: "postgres://db:5432/myapp"
  LOG_LEVEL: "info"
  config.yaml: |
    server:
      port: 8080
      timeout: 30s
```

```yaml
# Use it in a Pod — as environment variables
spec:
  containers:
  - name: app
    envFrom:
    - configMapRef:
        name: app-config

# Use it as a mounted file
  volumeMounts:
  - name: config
    mountPath: /etc/config
volumes:
- name: config
  configMap:
    name: app-config
```

**When to use ConfigMaps vs baking config into the image:**
Config that changes between environments (dev/staging/prod) goes in ConfigMaps. Config that is truly constant and part of the application goes in the image. Never bake environment-specific values into Docker images.

---

### Secrets — Sensitive Data

Secrets work exactly like ConfigMaps but are for sensitive values. Kubernetes stores them base64-encoded (not encrypted by default — encryption at rest must be configured separately).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
data:
  password: cGFzc3dvcmQxMjM=   # base64("password123") — NOT encryption, just encoding
```

**Important:** base64 is encoding, not encryption. Anyone with `kubectl get secret -o yaml` can decode it. In production, use:
- **External Secrets Operator + AWS Secrets Manager** — what your project uses
- **HashiCorp Vault** — the industry standard for large organisations
- **Sealed Secrets** — encrypts the secret YAML itself so it's safe to store in Git

**In your project:** The AlertManager SMTP secret was created manually then deleted to demonstrate the problem. ESO + AWS Secrets Manager solved it — the secret now recreates itself automatically on any cluster because it's fetched from AWS rather than stored in the cluster.

---

### Namespaces — Virtual Clusters Within a Cluster

Namespaces let you divide one Kubernetes cluster into isolated sections. Objects in different namespaces can have the same name. Resource quotas can be applied per namespace.

```
cluster
  ├── namespace: online-boutique   (your 12 microservices)
  ├── namespace: monitoring        (Prometheus, Grafana, Loki)
  ├── namespace: argocd            (ArgoCD)
  ├── namespace: external-secrets  (ESO)
  ├── namespace: kube-system       (k3s internals, Traefik)
  └── namespace: default           (objects with no namespace specified)
```

**Cross-namespace communication:** Services can be reached across namespaces using the full DNS name:
```
http://loki.monitoring.svc.cluster.local:3100
        ↑    ↑          ↑
     service namespace  cluster suffix
```

Short form (within same namespace): just `http://loki:3100`

---

### Requests and Limits — The Scheduling Contract

This is one of the most important things to understand in Kubernetes. You've experienced it directly.

```yaml
resources:
  requests:        # what Kubernetes RESERVES for scheduling
    cpu: 100m      # 100 millicores = 0.1 vCPU
    memory: 128Mi
  limits:          # the maximum the container is ALLOWED to use
    cpu: 500m
    memory: 256Mi
```

**CPU math:**
```
1 CPU core = 1000m (millicores)
100m = 10% of one core
500m = half a core
2000m = 2 full cores
```

**The two separate systems:**

| | Requests | Limits |
|---|---|---|
| Used by | Scheduler (placement) | Kernel (enforcement) |
| Effect if exceeded | Pod won't be placed | CPU: throttled. Memory: killed (OOMKilled) |
| Should equal | Typical/average usage | Peak/burst usage |

**The deadlock you experienced explained:**
```
Node: 2000m total CPU
11 boutique services × 140m avg requests = 1540m reserved
Monitoring: 400m reserved
Total: 1940m (97% reserved)

Rolling update adds second generation:
1940m existing + 1540m new = 3480m needed
3480m > 2000m available → new pods can't be scheduled → deadlock
```

**Rule:** Set requests based on observed average usage (from Prometheus). Set limits at 2-3× requests to allow for bursts. Never set requests equal to limits unless you know exactly what you're doing.

---

## Part 4 — Getting Traffic In (Ingress)

Three ways external traffic reaches your pods. Understanding the difference is essential.

### NodePort — Direct Node Access

```
Internet → Node IP:30080 → Service → Pod
```

A port is opened on every node in the range 30000-32767. Anyone who knows the node's IP and port can reach the service. Simple, but ports are ugly (`:30080`). Used for things that don't need a clean URL — your ArgoCD UI runs on NodePort 30080, Grafana on 30030, AlertManager on 30031.

---

### LoadBalancer — Cloud Provider Integration

```
Internet → Cloud Load Balancer (ELB on AWS) → Node → Service → Pod
```

You create a Service of type `LoadBalancer`. The cloud provider (AWS, GCP, Azure) sees this request and automatically provisions a load balancer with a public IP/hostname. Traffic enters the load balancer and is distributed across nodes.

On k3s (no cloud provider): Klipper ServiceLB handles this by creating a DaemonSet pod that binds directly to the node's port. This is why it conflicted with Traefik — both were trying to own port 80.

---

### Ingress — HTTP Routing Rules (the correct approach for HTTP)

```
Internet → Ingress Controller (Traefik) → Ingress Rules → Service → Pod
```

An Ingress is not a service type — it is a Kubernetes object that defines HTTP routing rules. An IngressController (like Traefik or NGINX) reads these rules and routes traffic accordingly.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: online-boutique
spec:
  rules:
  - host: shop.example.com           # optional: route by hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
  - host: admin.example.com          # different hostname → different service
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: admin-panel
            port:
              number: 80
```

**Why Ingress is better than NodePort/LoadBalancer for HTTP:**
- One Ingress controller handles all HTTP traffic (one port 80/443)
- Route different paths or hostnames to different services
- TLS termination in one place
- One load balancer cost instead of one per service

**In your project:** Your `ingress.yaml` in the Helm chart routes all traffic on port 80 to the frontend service. Traefik is the IngressController — it's already installed by k3s and ready to process Ingress rules. This is what actually serves your website. The LoadBalancer service (`externalService: true`) was a duplicate that conflicted.

---

## Part 5 — Storage (How Data Survives Pod Death)

Pods are ephemeral. Their filesystems are too — when a pod dies, everything written to its container filesystem is gone. For databases and stateful applications, you need storage that outlives pods.

### The Three Objects

```
StorageClass     → defines HOW to provision storage (which type, which cloud)
PersistentVolume → a piece of actual storage (1 disk = 1 PV)
PersistentVolumeClaim → a pod's request for storage (I need 10GB)
```

### How They Connect

```
StorageClass: "give me SSD storage on this cloud"
     ↓  (admin creates or cloud auto-creates)
PersistentVolume: "here is a 10GB SSD disk"
     ↓  (pod claims it)
PersistentVolumeClaim: "I need 10GB, give me a PV that matches"
     ↓  (scheduler mounts it)
Pod: "/data is now the actual disk, survives pod restart"
```

```yaml
# PVC — what your pod declares
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: database-storage
spec:
  accessModes:
  - ReadWriteOnce          # one pod can read/write at a time
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard

# Pod using the PVC
spec:
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: database-storage
  containers:
  - name: postgres
    volumeMounts:
    - name: data
      mountPath: /var/lib/postgresql
```

**Access modes:**
- `ReadWriteOnce` — one node reads and writes (most databases)
- `ReadOnlyMany` — many nodes can read (static files, assets)
- `ReadWriteMany` — many nodes can read and write (shared filesystems, needs special storage)

**In your project:** Redis (used by cartservice for shopping cart sessions) uses a PVC to persist cart data. k3s's Local Path Provisioner creates PVs automatically using the node's local disk. In production on AWS, you'd use the EBS CSI driver which creates actual EBS volumes.

---

## Part 6 — Scaling (How Kubernetes Handles Load)

Three levels of scaling in Kubernetes. Understanding all three and when to use each is what separates a junior from a senior engineer.

### HPA — Horizontal Pod Autoscaler (scale pods)

```
High CPU on pods → HPA creates more pods
Low CPU on pods → HPA removes pods (after cooldown)
```

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: frontend-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: frontend
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50   # scale up when average CPU > 50% of request
```

**How it calculates:**
```
Current pods: 2
Current avg CPU utilisation: 80%
Target utilisation: 50%
Desired pods = ceil(2 × (80/50)) = ceil(3.2) = 4 pods
```

**Important:** HPA needs `metrics-server` to work (already installed in k3s). It reads actual pod CPU/memory usage from metrics-server and compares against the target.

**Scale-up vs scale-down timing:**
- Scale-up: immediate (or after `stabilizationWindowSeconds`, default 0)
- Scale-down: after 5 minutes of low usage by default (prevents thrashing)

---

### VPA — Vertical Pod Autoscaler (resize pods)

Instead of adding more pods, VPA adjusts the CPU/memory requests of existing pods based on observed usage. If your pod requests 100m CPU but consistently uses 20m, VPA will lower the request to 25m. If it uses 400m, VPA will raise the request.

**VPA vs HPA:**
- **HPA**: "add more copies of the pod" — good for stateless workloads
- **VPA**: "give each pod more/less resources" — good for stateful workloads, tuning requests
- They should not both manage the same metric (don't use both CPU-based HPA and VPA together)

**In your project:** VPA would have automatically set the CPU requests to the right values instead of you manually reading Prometheus metrics and calculating 50m vs 200m. This is the production approach.

---

### Cluster Autoscaler (add/remove nodes)

When HPA wants to scale pods but there are no nodes with enough resources, the Cluster Autoscaler (CA) adds a new node. When nodes are underutilised, CA removes them.

```
HPA: "I need 5 pods"
Scheduler: "No room on existing nodes, 2 pods are Pending"
Cluster Autoscaler: "I see 2 Pending pods, requesting a new node from AWS"
AWS: "New EC2 instance starting"
Scheduler: "New node available, placing the 2 Pending pods"
```

**Your setup:** You have a single node — no Cluster Autoscaler. HPA will work (pods scale up) but if you hit node capacity, pods go Pending. In production on EKS, CA+HPA work together: HPA scales pods, CA scales nodes when pods can't be placed.

---

## Part 7 — Security (RBAC, NetworkPolicy, Secrets)

### RBAC — Who Can Do What

RBAC stands for Role-Based Access Control. It answers: "is this identity allowed to perform this action on this resource?"

**Four objects:**

```
ServiceAccount  → an identity for a pod (not a human user)
Role            → list of permissions within one namespace
ClusterRole     → list of permissions across all namespaces
RoleBinding     → attach a Role to a ServiceAccount (or user)
ClusterRoleBinding → attach a ClusterRole to a ServiceAccount (or user)
```

```yaml
# Step 1: Create an identity for your pod
apiVersion: v1
kind: ServiceAccount
metadata:
  name: monitoring-reader
  namespace: monitoring

# Step 2: Define what it's allowed to do
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: online-boutique
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]   # read only — no create, delete, update

# Step 3: Connect the identity to the permissions
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: online-boutique
subjects:
- kind: ServiceAccount
  name: monitoring-reader
  namespace: monitoring
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

**In your project:** Your Jenkins EC2 instance has an IAM role that allows ECR push/pull. Your k3s instance has a different IAM role that allows ECR pull only. This is the IAM equivalent of RBAC — least privilege enforced at the identity level. Jenkins should never be able to do everything k3s can, and k3s should never be able to do everything Jenkins can.

**The API groups:**
```
""                    → core resources (pods, services, configmaps, secrets)
apps                  → deployments, replicasets, statefulsets, daemonsets
autoscaling           → horizontalpodautoscalers
networking.k8s.io     → ingresses, networkpolicies
rbac.authorization.k8s.io → roles, clusterroles, bindings
```

---

### NetworkPolicy — Kubernetes Firewall Rules

By default, every pod can talk to every other pod in the cluster. NetworkPolicies let you lock this down.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: online-boutique
spec:
  podSelector: {}          # applies to all pods in namespace
  policyTypes:
  - Ingress
  ingress: []              # no ingress rules = deny all incoming traffic
```

```yaml
# More useful: only allow frontend to receive traffic from Traefik
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system   # allow from kube-system (Traefik)
    ports:
    - port: 8080
```

**Important:** NetworkPolicies are enforced by the CNI plugin. k3s uses Flannel by default, which does NOT enforce NetworkPolicies. For NetworkPolicy enforcement on k3s you need Calico or Cilium. On EKS, you use Amazon VPC CNI with the NetworkPolicy controller.

---

### Health Probes — How Kubernetes Knows a Pod Is Healthy

Three types. Understanding all three is essential.

```yaml
spec:
  containers:
  - name: app
    
    # Liveness probe — is the container alive?
    # If this fails → restart the container
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 10    # wait 10s before first check
      periodSeconds: 10          # check every 10s
      failureThreshold: 3        # restart after 3 consecutive failures

    # Readiness probe — is the container ready to receive traffic?
    # If this fails → remove from Service endpoints (stop sending traffic)
    # Does NOT restart the container
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      periodSeconds: 5
      failureThreshold: 3

    # Startup probe — is the container still starting up?
    # Disables liveness probe until startup succeeds
    # For slow-starting applications (Java apps, large models)
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30       # allow 5 minutes for startup (30 × 10s)
      periodSeconds: 10
```

**Why readiness matters for rolling updates:**
During a rolling update, Kubernetes will NOT terminate old pods until new pods pass their readiness probe. If you have no readiness probe, Kubernetes assumes the pod is ready the moment the container starts — which may be before your application has finished initializing. Users get errors.

**The difference in one sentence:**
- Liveness = "is the application healthy?" (restart if not)
- Readiness = "should the application receive traffic?" (remove from load balancer if not)

---

## Part 8 — Advanced Scheduling

### Taints and Tolerations

**Taints** are marks on nodes that say "don't place pods here unless they explicitly tolerate this."
**Tolerations** on pods say "I accept this taint, place me here anyway."

```yaml
# Taint a node (mark it as GPU-only)
kubectl taint nodes gpu-node gpu=true:NoSchedule

# Pod without toleration → will NOT be scheduled on gpu-node
# Pod with toleration → CAN be scheduled on gpu-node
spec:
  tolerations:
  - key: "gpu"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

**Three taint effects:**
- `NoSchedule` — don't place new pods here (existing pods unaffected)
- `PreferNoSchedule` — try not to place pods here, but will if no other option
- `NoExecute` — evict existing pods too (use for draining a node)

**Real use case:** In a production cluster, you might taint nodes with high-memory SSDs for database workloads, GPU nodes for ML workloads, and spot instances for batch jobs. Each workload type only runs on the appropriate nodes.

---

### Pod Affinity and Anti-Affinity

Where taints push pods away from nodes, affinity pulls pods toward (or away from) specific nodes or other pods.

```yaml
spec:
  affinity:
    # Node affinity: prefer nodes in eu-central-1a
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 1
        preference:
          matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values: ["eu-central-1a"]

    # Pod anti-affinity: don't place two frontend pods on the same node
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: frontend
        topologyKey: kubernetes.io/hostname
```

**`required` vs `preferred`:**
- `required` — hard rule, pod stays Pending if no node matches
- `preferred` — soft rule, try to satisfy but schedule anywhere if not possible

**Common real-world use:** Anti-affinity to spread replicas across availability zones. If one AZ goes down, you still have replicas in others.

---

### Pod Disruption Budgets — Guaranteed Availability During Maintenance

When you drain a node (for maintenance, upgrades, or scale-down), Kubernetes starts evicting pods. A PDB says "you can only disrupt this many pods at once."

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
spec:
  minAvailable: 1       # always keep at least 1 pod running
  selector:
    matchLabels:
      app: frontend
```

Without a PDB, draining a node could terminate all your pods simultaneously, causing complete downtime. With `minAvailable: 1`, Kubernetes ensures at least one pod is always serving traffic during the drain.

---

## Part 9 — The Operator Pattern (How Production Tools Work)

### Custom Resource Definitions (CRDs)

Kubernetes ships with built-in resource types: Pods, Deployments, Services. CRDs let you add your own resource types.

```yaml
# ArgoCD defines this custom resource type
apiVersion: argoproj.io/v1alpha1
kind: Application              # ← this is a CRD, not a built-in Kubernetes type
metadata:
  name: online-boutique
spec:
  source:
    repoURL: https://github.com/Dennis4507/cloudcommerce-devops.git
    path: kubernetes/apps/online-boutique
```

When you `kubectl apply` an ArgoCD Application, you're not using a Kubernetes built-in — you're using a custom type that ArgoCD registered with the API server.

**CRDs + Controllers = Operators:**
- The CRD defines the new resource type
- A custom controller watches for those resources
- The controller does whatever work the resource represents

ArgoCD works like this:
```
You apply an Application CRD
    ↓
ArgoCD's Application controller (running as a pod) watches for Application objects
    ↓
Controller reads the Application spec (Git URL, path)
    ↓
Controller clones the repo, renders the Helm chart
    ↓
Controller compares rendered manifests to cluster state
    ↓
Controller applies the diff (reconciliation loop)
    ↓
Repeat every 3 minutes
```

**Prometheus Operator works the same way:**
```
You apply a ServiceMonitor CRD
    ↓
Prometheus Operator controller watches for ServiceMonitor objects
    ↓
Controller updates Prometheus's config to scrape the new target
    ↓
No need to edit prometheus.yml manually ever again
```

**External Secrets Operator:**
```
You apply an ExternalSecret CRD
    ↓
ESO controller watches for ExternalSecret objects
    ↓
Controller reads from AWS Secrets Manager
    ↓
Controller creates a Kubernetes Secret with the fetched value
    ↓
Re-syncs every hour to keep it fresh
```

**This is why operators are powerful:** You define what you want (in a YAML file), the operator figures out how to make it real. The same reconciliation loop pattern, applied to complex multi-step operations.

---

## Part 10 — What Happens Step by Step (The Full Flow)

### When you push code to GitHub and the boutique deploys

```
1. You push to microservices-demo on GitHub
       ↓
2. GitHub sends webhook → POST to http://jenkins-ip:8080/github-webhook/
       ↓
3. Jenkins pipeline starts:
   a. Checkout code (clone the repo)
   b. docker build -t cloudcommerce/frontend:abc123 .
   c. trivy image scan (check for CVEs)
   d. aws ecr get-login-password | docker login
   e. docker push to ECR
   f. clone cloudcommerce-devops
   g. update values.yaml: tag: "abc123"
   h. git commit and push (with [skip ci])
       ↓
4. ArgoCD polls GitHub every 3 minutes, detects new commit in cloudcommerce-devops
       ↓
5. ArgoCD Application controller:
   a. Clones the repo
   b. Runs: helm template kubernetes/apps/online-boutique --values values.yaml
   c. Compares rendered manifests to current cluster state
   d. Detects: Deployment frontend has image tag changed abc122 → abc123
       ↓
6. ArgoCD applies the diff:
   kubectl apply -f (the updated Deployment)
       ↓
7. Deployment controller detects new desired image tag
       ↓
8. Creates new ReplicaSet with image abc123
       ↓
9. ReplicaSet controller creates new Pod
       ↓
10. Scheduler finds a node with enough CPU/memory requests available
        ↓
11. Scheduler assigns pod to the node, writes to etcd
        ↓
12. kubelet on that node detects it has a new pod assigned
        ↓
13. kubelet tells containerd to pull the image from ECR
        ↓
14. containerd checks registries.yaml → gets ECR credentials
        ↓
15. containerd pulls the image from ECR
        ↓
16. Container starts, readiness probe begins checking /healthz
        ↓
17. Readiness probe passes → pod added to Service endpoints
        ↓
18. Deployment controller scales down old ReplicaSet (terminates old pod)
        ↓
19. Traffic now flows to the new pod
        ↓
20. Jenkins' automated commit triggers ArgoCD sync again → ArgoCD finds no diff → reports Synced
```

This is the complete story of one deployment. Every step is a reconciliation loop doing its job.

---

## Part 11 — Production Architecture (Real-World Design)

### What Your Setup Teaches vs Production Differences

| Your Setup | Production (EKS/GKE) | Why Different |
|---|---|---|
| Single node (t3.large) | Multiple nodes across 3 AZs | No single point of failure |
| k3s (single binary) | Managed control plane (EKS) | AWS manages the control plane — no etcd to back up |
| Manual ECR token refresh | IAM Roles for Service Accounts (IRSA) | Pods get AWS credentials directly, no token management |
| NodePort for monitoring | Internal load balancers | Security — not exposed to internet |
| Traefik ingress | AWS ALB Ingress Controller | Native AWS integration, WAF support |
| Local Path PVs | EBS CSI driver | Actual cloud block storage, multi-AZ |
| No NetworkPolicy | Calico or Cilium CNI | Zero-trust networking between pods |
| Manual HPA | KEDA (event-driven autoscaling) | Scale on SQS queue depth, Kafka lag, custom metrics |

---

### The Production Architecture Pattern

```
                    Internet
                       ↓
              Route53 (DNS)
                       ↓
            AWS ALB (load balancer)
                       ↓
         ┌─────────────┴─────────────┐
         ↓                           ↓
   AZ eu-central-1a          AZ eu-central-1b
   ┌─────────────────┐       ┌─────────────────┐
   │  Node 1 (t3.xl) │       │  Node 2 (t3.xl) │
   │  frontend-pod-1 │       │  frontend-pod-2 │
   │  cartservice-1  │       │  cartservice-2  │
   └─────────────────┘       └─────────────────┘
         ↓                           ↓
   ┌─────────────────────────────────────────┐
   │         EKS Control Plane (AWS managed)  │
   │         etcd (3 replicas, encrypted)     │
   └─────────────────────────────────────────┘
         ↓
   ┌─────────────────────────────────────────┐
   │   AWS RDS (PostgreSQL, Multi-AZ)         │
   │   ElastiCache (Redis, Multi-AZ)          │
   └─────────────────────────────────────────┘
```

The core principle: **no single point of failure at any layer.** Multiple nodes, multiple AZs, managed control plane, managed databases.

---

### What to Build Next to Get to Production Level

Your current project covers:
- ✅ IaC (Terraform)
- ✅ Configuration management (Ansible)
- ✅ CI/CD (Jenkins)
- ✅ GitOps (ArgoCD)
- ✅ Observability (Prometheus, Grafana, Loki, AlertManager)
- ✅ Security scanning (Trivy)
- ✅ Secrets management (ESO + AWS Secrets Manager)
- ✅ Autoscaling concepts (HPA — coming next)

Things that would complete the picture for production:
- **IRSA** — remove the cron job ECR hack, use native AWS auth
- **NetworkPolicies** (requires Calico/Cilium) — zero-trust pod networking
- **Multi-node** — add a second k3s node to see real scheduling distribution
- **PodDisruptionBudgets** — guarantee availability during updates
- **Resource Quotas** — per-namespace resource limits
- **KEDA** — event-driven autoscaling beyond CPU/memory

---

## Quick Reference — The Answers to Common Interview Questions

### "Explain the Kubernetes architecture"
> "Kubernetes has a control plane and worker nodes. The control plane has four components: etcd (the database storing all cluster state), the API server (the front door — everything communicates through it), the scheduler (decides which node each pod goes on based on resource availability and constraints), and the controller manager (runs all the reconciliation loops that keep desired state matching actual state). Worker nodes run the kubelet (the node agent), containerd (the container runtime), and the CNI plugin (handles pod networking). On k3s, all of these run on a single machine as one binary."

### "How does a pod end up running on a node?"
> "You apply a Deployment which creates a ReplicaSet which creates a Pod object in etcd. The Pod has no node assigned yet — it's Pending. The scheduler watches for unassigned pods, runs its filter (does any node have enough resources?) and scoring (which node is best?) algorithms, and writes the node assignment back to etcd. The kubelet on that node is watching the API server for pods assigned to it. When it sees the new assignment, it tells containerd to pull the image and start the container."

### "What's the difference between CPU requests and limits?"
> "Requests are what the scheduler uses for placement decisions — when a pod says it requests 100m CPU, the scheduler reserves that on a node. Limits are enforced at runtime — if a pod tries to use more CPU than its limit, it gets throttled. Memory is different: if a pod exceeds its memory limit, the kernel kills it (OOMKilled). On a single-node cluster I ran, all pods were requesting 1500m total but only using about 200m actual CPU. This created a rolling update deadlock — the scheduler thought the node was full even though it was actually mostly idle. The fix was reducing requests to match observed usage."

### "What is a Service and why do you need it?"
> "Pods are ephemeral — they die and are replaced with new pods that have different IPs. A Service is a stable endpoint that routes traffic to whatever pods currently match its selector. You connect to the Service, the Service finds the current pods via labels. Without Services, every time a pod restarted you'd need to update every other service's configuration to point to the new IP. Services also provide load balancing across multiple replicas of the same pod."

### "How does ArgoCD work?"
> "ArgoCD is an operator — it's a controller that watches Custom Resource Definitions called Application objects. Each Application says 'here is a Git repo and path, keep the cluster matching what's in Git.' The controller clones the repo, renders the Helm chart or kustomize manifests, compares the rendered YAML to what's in the cluster, and applies any differences. It repeats this every 3 minutes. This is GitOps: Git is the single source of truth, the cluster continuously reconciles toward it, and every change is a git commit with full audit history."

---

## The One-Page Summary

```
Kubernetes = reconciliation loops running forever
           = desired state (YAML) vs actual state (cluster) vs action to close the gap

Control plane:
  etcd          → database (the memory of the cluster)
  API server    → front door (everything goes through port 6443)
  Scheduler     → placement (which node gets which pod)
  Controller Mgr → loops (Deployment→RS→Pod, Node health, Endpoints, etc.)

Worker node:
  kubelet       → agent (watches for pods assigned to this node, starts them)
  containerd    → runtime (actually runs the containers)
  CNI           → networking (gives each pod a unique IP)

Core objects:
  Pod           → one or more containers, one IP, ephemeral
  Deployment    → desired number of identical pods, manages rolling updates
  Service       → stable endpoint, routes to pods by label, has a DNS name
  ConfigMap     → non-sensitive config injected into pods
  Secret        → sensitive config, base64 encoded, use ESO+Vault in production
  Ingress       → HTTP routing rules, one entry point for all HTTP traffic
  HPA           → scale pods based on CPU/memory/custom metrics
  PVC           → claim for storage that outlives pods

Traffic flow: Internet → LoadBalancer/NodePort → Ingress → Service → Pod
Networking:   Pod DNS = <service>.<namespace>.svc.cluster.local
Storage:      StorageClass → PersistentVolume → PersistentVolumeClaim → Pod

Security:     RBAC = who can do what (ServiceAccount + Role + RoleBinding)
              NetworkPolicy = which pods can talk to which pods
              Secrets management = never commit secrets to Git

Scaling:      HPA = more pods        (horizontal, stateless workloads)
              VPA = bigger pods      (vertical, stateful workloads)
              Cluster Autoscaler = more nodes (when HPA needs room)

The Operator pattern:
  CRD = new resource type you define
  Controller = watches for that type, does whatever work it represents
  Examples: ArgoCD (Application CRD), Prometheus (ServiceMonitor CRD), ESO (ExternalSecret CRD)
```
