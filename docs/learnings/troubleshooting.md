# Troubleshooting Reference — CloudCommerce DevOps

Every real issue encountered during this project, documented with the exact CLI output, root cause, fix, and the reasoning behind how we diagnosed it.

**How to use this file:** Search for the error message or symptom you're seeing. Each entry explains not just *what* to run but *why* — so you build intuition for the next problem, not just a recipe to copy.

---

## Table of Contents

1. [SSH — Unprotected Private Key File (0777 permissions)](#1-ssh--unprotected-private-key-file)
2. [SSH — Key Not Found in WSL](#2-ssh--key-not-found-in-wsl)
3. [Ansible — Jenkins GPG Key Error](#3-ansible--jenkins-gpg-key-error)
4. [Jenkins — Java 17 Not Supported](#4-jenkins--java-17-not-supported)
5. [k3s — x509 Certificate / TLS Error After Reinstall](#5-k3s--x509-certificate--tls-error-after-reinstall)
6. [kubectl — Permission Denied Reading kubeconfig](#6-kubectl--permission-denied-reading-kubeconfig)
7. [kubectl — TLS Handshake Timeout (Node Overloaded)](#7-kubectl--tls-handshake-timeout-node-overloaded)
8. [ArgoCD — Install Conflicts (ServerSideApply)](#8-argocd--install-conflicts-serversideapply)
9. [ArgoCD — Application Synced but Pods Not Running (ECR Auth)](#9-argocd--application-synced-but-pods-not-running-ecr-auth)
10. [Rolling Update Deadlock — Old Pods Blocking New Pods](#10-rolling-update-deadlock--old-pods-blocking-new-pods)
11. [Helm — Removing a Chart Default Value (cpu: null)](#11-helm--removing-a-chart-default-value-cpu-null)
12. [StatefulSet — Pod Stuck Pending Despite Updated Template](#12-statefulset--pod-stuck-pending-despite-updated-template)
13. [Loki — Wrong Service Name (Release Name vs Chart Name)](#13-loki--wrong-service-name-release-name-vs-chart-name)
14. [Grafana — CrashLoopBackOff (Two isDefault Datasources)](#14-grafana--crashloopbackoff-two-isdefault-datasources)
15. [ArgoCD — ignoreDifferences Not Preventing Revert](#15-argocd--ignoredifferences-not-preventing-revert)
16. [AlertManager — undefined receiver "null" used in route](#16-alertmanager--undefined-receiver-null-used-in-route)
17. [Node Memory Exhaustion — Full Cluster Freeze](#17-node-memory-exhaustion--full-cluster-freeze)
18. [git push Rejected — Jenkins Pushed First](#18-git-push-rejected--jenkins-pushed-first)

---

## 1. SSH — Unprotected Private Key File

### Symptom
```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@         WARNING: UNPROTECTED PRIVATE KEY FILE!          @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Permissions 0777 for '/mnt/c/Users/OnlyM/Devops Project/cloudcommerce-devops/terraform/keys/cloudcommerce-dev-key' are too open.
It is required that your private key files are NOT accessible by others.
This private key will be ignored.
ubuntu@63.184.235.88: Permission denied (publickey).
```

### Root Cause
The SSH key lives on the Windows NTFS filesystem (`/mnt/c/...`). When you run `chmod 600` on an NTFS-mounted path inside WSL, the command appears to succeed but the permissions don't actually change — NTFS doesn't support Unix permission bits. SSH sees 0777 and refuses to use the key.

### Troubleshooting Methodology
SSH requires the private key to be readable only by the owner (0600). This is a security check — if anyone can read your private key, it's compromised. The fix isn't to bypass the check, it's to move the key to a filesystem that supports Unix permissions: the WSL Linux filesystem.

### Fix
```bash
# Copy the key into WSL's own filesystem (not /mnt/c/)
mkdir -p ~/.ssh
cp /mnt/c/Users/OnlyM/Devops\ Project/cloudcommerce-devops/terraform/keys/cloudcommerce-dev-key ~/.ssh/cloudcommerce-dev-key

# chmod now works because ~/.ssh is on the Linux ext4 filesystem
chmod 600 ~/.ssh/cloudcommerce-dev-key

# SSH works
ssh -i ~/.ssh/cloudcommerce-dev-key ubuntu@63.184.235.88
```

### Result
```
Welcome to Ubuntu 22.04.3 LTS
ubuntu@ip-10-0-1-23:~$
```

### Why This Works
`~/.ssh/` in WSL is on the Linux ext4 filesystem — it fully supports Unix permission bits. The NTFS mount at `/mnt/c/` doesn't. Moving the file to a real Linux path is the correct fix, not a workaround.

---

## 2. SSH — Key Not Found in WSL

### Symptom
```
Warning: Identity file /home/denis/.ssh/cloudcommerce-key.pem not accessible: No such file or directory.
ubuntu@63.184.235.88: Permission denied (publickey).
```

### Root Cause
The key filename isn't `cloudcommerce-key.pem`. The actual key in this project has no `.pem` extension and is at `terraform/keys/cloudcommerce-dev-key`. The SSH key path in `ansible.cfg` (`private_key_file = ~/.ssh/cloudcommerce-dev-key`) reveals where we previously put it.

### Troubleshooting Methodology
When an SSH key isn't found, check three things in order:
1. What is the actual filename? (glob the keys directory)
2. Where did the Ansible setup put it? (check ansible.cfg)
3. Is it in WSL's home or still only in Windows?

### Fix
```bash
# Find the actual key
ls /mnt/c/Users/OnlyM/Devops\ Project/cloudcommerce-devops/terraform/keys/
# cloudcommerce-dev-key  cloudcommerce-dev-key.pub

# Use the correct path
ssh -i ~/.ssh/cloudcommerce-dev-key ubuntu@63.184.235.88
```

---

## 3. Ansible — Jenkins GPG Key Error

### Symptom
```
TASK [Add Jenkins apt key] *****
fatal: [jenkins]: FAILED! => {
    "msg": "Failed to validate the SSL certificate for pkg.jenkins.io..."
}
```
And later:
```
W: GPG error: https://pkg.jenkins.io/debian-stable binary/ Release:
The following signatures couldn't be verified because the public key is not available: NO_PUBKEY FCEF32E745F2C3D5
```

### Root Cause
Jenkins changed their GPG key signing approach. Older Ansible playbook tasks that downloaded the key via `apt-key add` stopped working because:
1. Jenkins moved to a new key format (armored vs binary)
2. `apt-key` is deprecated in Ubuntu 22.04 in favour of per-repository keyrings

### Troubleshooting Methodology
GPG errors mean the package manager can't verify the authenticity of the packages. The key either changed, the download URL changed, or the key format changed. Check the official Jenkins installation docs — they update when the signing approach changes.

### Fix (in Ansible playbook)
```yaml
# Old (broken):
- name: Add Jenkins apt key
  apt_key:
    url: https://pkg.jenkins.io/debian-stable/jenkins.io.key

# New (working) — download armored key directly to keyring directory:
- name: Add Jenkins apt key
  shell: |
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
  args:
    creates: /usr/share/keyrings/jenkins-keyring.gpg

- name: Add Jenkins repository
  apt_repository:
    repo: "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/"
```

### Result
```
TASK [Add Jenkins apt key] *** ok
TASK [Add Jenkins repository] *** ok
TASK [Install Jenkins] *** ok
```

---

## 4. Jenkins — Java 17 Not Supported

### Symptom
```
TASK [Start Jenkins service] *****
fatal: [jenkins]: FAILED! => {
    "msg": "Unable to start service jenkins: Job for jenkins.service failed"
}

# Checking Jenkins logs:
jenkins: error: unsupported Java version 17
Jenkins requires Java 11, 17 is NOT supported
```

Wait — then it flipped. Later Jenkins versions require Java 21:
```
Jenkins requires Java 17 or Java 21. Java 11 is NOT supported.
```

### Root Cause
Jenkins version requirements changed between releases. The Ansible playbook installed a specific Jenkins version that required Java 21, but the playbook was installing Java 17. The requirement matrix: older Jenkins → Java 11/17, newer Jenkins → Java 17/21.

### Troubleshooting Methodology
When a service fails to start, always check its logs (`journalctl -u jenkins -n 50`). Java version mismatches are one of the most common Jenkins startup failures. Check the Jenkins release notes for the exact Java requirement of the version being installed.

### Fix (in Ansible playbook)
```yaml
# Change Java installation from Java 17 to Java 21
- name: Install Java 21
  apt:
    name: openjdk-21-jdk
    state: present
```

### Result
```
TASK [Install Java 21] *** ok
TASK [Start Jenkins service] *** ok

# Verify:
ubuntu@jenkins:~$ java -version
openjdk version "21.0.2" 2024-01-16
```

---

## 5. k3s — x509 Certificate / TLS Error After Reinstall

### Symptom
```
$ kubectl get nodes
Unable to connect to the server: x509: certificate is valid for 10.43.0.1,
127.0.0.1, not 63.184.235.88
```

Or:
```
error: error loading config file "/root/.kube/config":
x509: certificate signed by unknown authority
```

### Root Cause
When k3s is reinstalled, it generates a **new** TLS certificate for the API server. The old kubeconfig you copied before reinstall contains the old certificate — the new k3s doesn't recognise it. Additionally, the certificate only includes the cluster-internal IP (10.43.0.1) and localhost (127.0.0.1) as valid Subject Alternative Names (SANs), not the external IP.

If you're connecting via the public IP, you need to tell k3s to include that IP in the certificate when it's generated.

### Troubleshooting Methodology
x509 errors are always about certificate trust. Ask two questions:
1. Is this a stale certificate? (reinstall regenerates them)
2. Is the client connecting via an IP/hostname not listed in the cert's SANs?

Check with: `openssl s_client -connect <ip>:6443 | openssl x509 -noout -text | grep -A1 "Subject Alternative"`

### Fix — Reinstall k3s with correct SANs
```bash
# Uninstall existing k3s
/usr/local/bin/k3s-uninstall.sh

# Reinstall with the public IP added to TLS SANs
curl -sfL https://get.k3s.io | sh -s - \
  --tls-san 63.184.235.88 \
  --tls-san 10.0.1.23 \
  --write-kubeconfig-mode 644
```

### Result
```bash
$ openssl s_client -connect 63.184.235.88:6443 | openssl x509 -noout -text | grep -A5 "Subject Alternative"
X509v3 Subject Alternative Names:
    IP Address:10.43.0.1
    IP Address:127.0.0.1
    IP Address:63.184.235.88    # ← now included
    IP Address:10.0.1.23

$ kubectl get nodes
NAME            STATUS   ROLES                  AGE   VERSION
ip-10-0-1-23    Ready    control-plane,master   2m    v1.28.4+k3s2
```

---

## 6. kubectl — Permission Denied Reading kubeconfig

### Symptom
```
$ kubectl get pods
WARN[0000] Unable to read /etc/rancher/k3s/k3s.yaml, please start server with
--write-kubeconfig-mode or --write-kubeconfig-group to modify kube config permissions
error: error loading config file "/etc/rancher/k3s/k3s.yaml": open
/etc/rancher/k3s/k3s.yaml: permission denied
```

### Root Cause
k3s generates its kubeconfig at `/etc/rancher/k3s/k3s.yaml` with root-only permissions (0600). After a reboot, k3s regenerates this file and the permissions reset. The `ubuntu` user can't read it.

### Troubleshooting Methodology
When `kubectl` fails with permission denied on the config file — not on a resource — the issue is filesystem permissions, not Kubernetes RBAC. Check `ls -la /etc/rancher/k3s/k3s.yaml` to confirm. This happens specifically after reboots because k3s regenerates the file.

### Fix
```bash
# Make kubeconfig readable by all users (safe — it's a config file, not a secret key)
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# Verify
kubectl get nodes
```

### Result
```
NAME            STATUS   ROLES                  AGE   VERSION
ip-10-0-1-23    Ready    control-plane,master   5d    v1.28.4+k3s2
```

### Permanent Fix (in k3s install command)
```bash
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
```
This sets the file permissions at install time so they survive reboots.

---

## 7. kubectl — TLS Handshake Timeout (Node Overloaded)

### Symptom
```
$ kubectl get pods -n monitoring
Unable to connect to the server: net/http: TLS handshake timeout

$ kubectl top nodes
Unable to connect to the server: net/http: TLS handshake timeout

$ ssh -i ~/.ssh/cloudcommerce-dev-key ubuntu@63.184.235.88
# cursor just blinks — no response
```

### Root Cause
The EC2 instance is under severe memory pressure. When the node runs out of RAM:
1. The OS starts swapping (writing RAM contents to disk)
2. Everything — including the k3s API server — slows dramatically
3. The k3s API server can't complete TLS handshakes in time
4. kubectl commands time out before getting a response
5. SSH connections hang because the sshd process can't get CPU time

The k3s API server runs on the same node as all workloads — when the node is suffering, the control plane suffers too.

### Troubleshooting Methodology
TLS handshake timeout from kubectl almost always means one of two things:
1. The API server port (6443) is blocked by a firewall/security group
2. The node itself is overwhelmed

Distinguish them by trying SSH — if SSH also hangs, it's the node, not networking.

### Diagnosis (from AWS side when kubectl is unavailable)
Check EC2 metrics in AWS Console → EC2 → Instances → Monitoring tab → look at CPU utilisation and network. An overloaded node shows high CPU steal and memory metrics.

### Fix — EC2 Reboot
When the node is completely unresponsive, the only option is a reboot from AWS Console:
- **Reboot** (preferred): keeps Elastic IP, clears memory, k3s restarts automatically
- **Stop + Start**: also works, keeps Elastic IP (because we use an Elastic IP), clears memory

After reboot, ArgoCD automatically reconciles all applications from Git — nothing needs to be done manually.

```bash
# After reboot, fix kubeconfig permissions:
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
kubectl get pods --all-namespaces
```

### Prevention
- Set accurate memory `requests` so Kubernetes scheduling reflects real usage
- Set memory `limits` to prevent pods from consuming unbounded memory
- AlertManager `HighNodeMemoryUsage` rule fires at 90% — early warning before it becomes critical

---

## 8. ArgoCD — Install Conflicts (ServerSideApply)

### Symptom
```
$ kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/install.yaml
...
error: Apply failed with 1 conflict: conflict with "argocd" using apps/v1:
/spec/template/spec/containers/0/resources
```

Or:
```
The CustomResourceDefinition "applications.argoproj.io" is invalid:
metadata.annotations: Too long: must have at most 262144 bytes
```

### Root Cause
The ArgoCD install manifest is large. When applied with `kubectl apply`, it stores the entire manifest in the resource's `last-applied-configuration` annotation. This annotation has a 256KB limit — ArgoCD's CRDs exceed it. Additionally, if ArgoCD was installed before and resources exist, field conflicts arise.

### Troubleshooting Methodology
"Annotation too long" or "conflict" errors on large manifests almost always mean server-side apply is needed. Server-side apply moves the field ownership tracking to the API server (where there's no size limit) instead of the client-side annotation.

### Fix
```bash
# Use server-side apply instead of client-side
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/install.yaml \
  --server-side \
  --force-conflicts
```

The `--force-conflicts` flag is needed if ArgoCD was partially installed before — it tells Kubernetes "I know there are conflicts, I'm taking ownership of these fields."

### Result
```
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io serverside-applied
...
deployment.apps/argocd-server serverside-applied
```

---

## 9. ArgoCD — Application Synced but Pods Not Running (ECR Auth)

### Symptom
```
$ kubectl get pods -n online-boutique
NAME                          READY   STATUS             RESTARTS   AGE
frontend-6b8d9b4c6-xp2jk      0/1     ErrImagePull       0          2m
cartservice-7d4f9c8b-kj3lm    0/1     ImagePullBackOff   0          2m
```

```
$ kubectl describe pod frontend-6b8d9b4c6-xp2jk -n online-boutique
Events:
  Warning  Failed  2m  kubelet  Failed to pull image
  "887654321.dkr.ecr.eu-central-1.amazonaws.com/frontend:latest":
  no basic auth credentials
```

ArgoCD shows the app as **Synced** and **Healthy** — but pods are failing.

### Root Cause
ArgoCD synced successfully (the Kubernetes manifests were applied correctly). The pods are failing because containerd (k3s's container runtime) can't authenticate with AWS ECR to pull the images. ECR requires AWS credentials — containerd doesn't have them by default.

ArgoCD's health check looks at the Deployment object, not the running pods — it reports Healthy even when all pods are in ImagePullBackOff.

### Troubleshooting Methodology
When ArgoCD shows Synced/Healthy but pods aren't running, the issue is below ArgoCD's visibility — it's in the container runtime. `kubectl describe pod` shows events including image pull failures with the exact error. "No basic auth credentials" means authentication is missing entirely.

### Fix — Configure containerd ECR credentials
```bash
# On the k3s node, create the containerd registry config directory
sudo mkdir -p /etc/rancher/k3s/

# Create the ECR registry configuration
sudo tee /etc/rancher/k3s/registries.yaml <<EOF
configs:
  "887654321.dkr.ecr.eu-central-1.amazonaws.com":
    auth:
      username: AWS
      password: $(aws ecr get-login-password --region eu-central-1)
EOF

# Restart k3s to pick up the new config
sudo systemctl restart k3s
```

### Result
```
$ kubectl get pods -n online-boutique
NAME                          READY   STATUS    RESTARTS   AGE
frontend-6b8d9b4c6-xp2jk      1/1     Running   0          30s
cartservice-7d4f9c8b-kj3lm    1/1     Running   0          30s
```

### Note
ECR tokens expire every 12 hours. For production, use the ECR credential helper or an IAM instance profile so k3s can refresh tokens automatically.

---

## 10. Rolling Update Deadlock — Old Pods Blocking New Pods

### Symptom
```
$ kubectl get pods -n online-boutique
NAME                            READY   STATUS             RESTARTS   AGE
frontend-7d9f8c-old             0/1     ImagePullBackOff   3          45m
frontend-9b4c2d-new             0/1     Pending            0          10m
```

New pod stuck `Pending` while old pod is stuck `ImagePullBackOff`. Neither progresses.

```
$ kubectl describe pod frontend-9b4c2d-new -n online-boutique
Events:
  Warning  FailedScheduling  Insufficient cpu. 0/1 nodes are available:
  1 Insufficient cpu. preemption: 0/1 nodes cannot be preempted.
```

### Root Cause
The rolling update created a new pod (new image tag) but the old pod — even though it's failing with ImagePullBackOff — still holds its CPU and memory **reservations**. Kubernetes scheduling is based on `requests`, not actual usage. A crashing pod still occupies its reserved resources on the scheduler's books.

On a single node with limited headroom, the deadlock forms:
- Old pod: crashing but holding reservations → new pod can't schedule
- New pod: can't start → Kubernetes won't terminate old pod (rolling update waits for new pod to be Running first)

### Troubleshooting Methodology
When a new pod is `Pending` during a rolling update, check node capacity:
```bash
kubectl describe node | grep -A 8 "Allocated resources"
```
If CPU or memory requests are at 90%+, and you have crashing pods, this is the deadlock. The crashing pods are the bottleneck.

### Fix
Delete the old crashing pod manually to free its reservations:
```bash
# Identify the old crashing pod
kubectl get pods -n online-boutique

# Delete it — Kubernetes won't automatically delete a crashing pod during rolling update
kubectl delete pod frontend-7d9f8c-old -n online-boutique
```

### Result
```
$ kubectl get pods -n online-boutique
# Old pod deleted → reservations freed → new pod schedules and starts
NAME                            READY   STATUS    RESTARTS   AGE
frontend-9b4c2d-new             1/1     Running   0          30s
```

### Prevention
On single-node clusters, use `Recreate` deployment strategy instead of `RollingUpdate`:
```yaml
spec:
  strategy:
    type: Recreate   # kill all old pods first, then create new ones
```
This prevents the deadlock at the cost of a brief downtime during updates — acceptable for development.

---

## 11. Helm — Removing a Chart Default Value (cpu: null)

### Symptom
```
$ kubectl get pods -n monitoring
NAME      READY   STATUS    RESTARTS   AGE
loki-0    0/1     Pending   0          5m

$ kubectl describe pod loki-0 -n monitoring
Events:
  Warning  FailedScheduling  Insufficient cpu. 0/1 nodes are available:
  1 node(s) had untolerated taint {node.kubernetes.io/not-ready: }:
  0/1 nodes are available: 1 Insufficient cpu.
```

We tried removing `cpu` from the values file:
```yaml
# Attempt 1 — simply omit cpu (DOES NOT WORK)
loki:
  resources:
    requests:
      memory: 64Mi
      # cpu is absent
```

Pod still shows `cpu: 50m` in its spec.

### Root Cause
Helm **merges** your values with the chart's default values — it does not replace them. Omitting a key from your values file leaves the chart default in place. The loki-stack chart defaults to `cpu: 50m` for the Loki pod. Omitting `cpu` from your values means the chart default of `50m` is used.

### Troubleshooting Methodology
When a Helm value change doesn't seem to take effect, verify what the chart's defaults are:
```bash
helm show values grafana/loki-stack --version 2.10.2 | grep -A5 "resources"
```
If the chart has a default, you must explicitly override it — not omit it.

### Fix — Set to null to explicitly remove the key
```yaml
loki:
  resources:
    requests:
      cpu: null    # explicitly removes chart default of 50m
      memory: 64Mi
```

`null` in YAML is a special value that Helm treats as "remove this key from the merged output." It's the only way to delete a chart default you don't want.

### Result
```bash
$ kubectl get pod loki-0 -n monitoring -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"100m","memory":"128Mi"},"requests":{"memory":"64Mi"}}
# cpu is absent from requests — pod schedules successfully
```

---

## 12. StatefulSet — Pod Stuck Pending Despite Updated Template

### Symptom
```
# We set cpu: null and ArgoCD synced — StatefulSet template updated
$ kubectl get statefulset loki -n monitoring -o jsonpath='{.spec.template.spec.containers[0].resources}'
{"limits":{"cpu":"100m","memory":"128Mi"},"requests":{"memory":"64Mi"}}
# Template looks correct — cpu removed

# But the pod still shows the old cpu:50m spec
$ kubectl get pod loki-0 -n monitoring -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"100m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
# Pod still has cpu: 50m — still Pending
```

### Root Cause
StatefulSet rolling updates only apply to **Running** pods. The update controller says: "I need to update loki-0 — but loki-0 is Pending, not Running. I'll wait until it's Running before updating it." It never runs, so it's never updated. Classic deadlock.

Additionally, when we tried deleting just the pod to force a recreate, a **timing race** occurred:
- We deleted loki-0
- Kubernetes immediately started creating a new loki-0
- The new pod used the StatefulSet's template — but ArgoCD hadn't finished applying the update yet
- The new pod got the old template (cpu: 50m)
- Still Pending

### Troubleshooting Methodology
When a StatefulSet template change isn't reflected in the pod:
1. Check the StatefulSet template vs the pod spec separately (as above)
2. If template is updated but pod isn't, check if the pod is Running (only Running pods get rolling updates)
3. If pod is Pending, deleting the pod alone won't work — it'll be recreated with the old spec due to the timing race

### Fix — Delete the entire StatefulSet
```bash
# Delete the StatefulSet entirely (not just the pod)
# ArgoCD will recreate it from Git with the current template
kubectl delete statefulset loki -n monitoring
```

When the StatefulSet is gone, ArgoCD detects the drift on its next sync (within 3 minutes) and recreates the StatefulSet fresh from Git with the current correct template. The new loki-0 pod starts with the updated spec.

### Result
```
$ kubectl get pods -n monitoring -w
# ArgoCD recreates StatefulSet with correct template
loki-0   0/1   ContainerCreating   0   5s
loki-0   1/1   Running             0   12s

$ kubectl get pod loki-0 -n monitoring -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"100m","memory":"128Mi"},"requests":{"memory":"64Mi"}}
# cpu removed — pod running
```

---

## 13. Loki — Wrong Service Name (Release Name vs Chart Name)

### Symptom
```
# In Grafana — data source test fails:
Unable to connect to Loki. Please check the server logs for more details.

# Promtail logs showing push failures
$ kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20
level=error msg="error sending batch" error="Post
http://loki-stack.monitoring.svc.cluster.local:3100/loki/api/v1/push:
dial tcp: lookup loki-stack.monitoring.svc.cluster.local: no such host"
```

### Root Cause
Kubernetes service names are determined by the **Helm release name**, not the chart name. The ArgoCD Application was named `loki`:

```yaml
metadata:
  name: loki   # ← this becomes the Helm release name
```

So the Helm release name is `loki`, and all resources are named `loki-*`. The Loki Service is named `loki`, not `loki-stack`.

Both our Grafana data source URL and Promtail push URL were configured with `loki-stack` — a service that doesn't exist.

### Troubleshooting Methodology
When a service can't connect to another service by name, always verify the actual service name in Kubernetes:
```bash
kubectl get svc -n monitoring | grep loki
```
Don't assume — the chart name, release name, and service name can all differ.

### Diagnosis
```bash
$ kubectl get svc -n monitoring | grep loki
loki              ClusterIP   10.43.14.72   <none>   3100/TCP   2h
loki-headless     ClusterIP   None          <none>   3100/TCP   2h
# Service is named 'loki' — not 'loki-stack'

# Verify Loki is healthy from inside the cluster:
$ kubectl exec -n monitoring $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}') -c grafana \
  -- wget -qO- http://loki.monitoring.svc.cluster.local:3100/ready
ready
# Network is fine — it was just the wrong URL
```

### Fix
Update all references from `loki-stack` to `loki`:

In `loki-stack-values.yaml`:
```yaml
promtail:
  config:
    clients:
      - url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
```

In `kube-prometheus-stack-values.yaml`:
```yaml
additionalDataSources:
  - name: Loki
    url: http://loki.monitoring.svc.cluster.local:3100
```

---

## 14. Grafana — CrashLoopBackOff (Two isDefault Datasources)

### Symptom
```
$ kubectl get pods -n monitoring
monitoring-grafana-755c9b8db7-t5xk7   2/3   CrashLoopBackOff   8 (40s ago)   6h

$ kubectl logs -n monitoring monitoring-grafana-755c9b8db7-t5xk7 -c grafana --tail=5
logger=provisioning level=error msg="Failed to provision data sources"
error="Datasource provisioning error: datasource.yaml config is invalid.
Only one datasource per organization can be marked as default"
Error: ✗ Datasource provisioning error: datasource.yaml config is invalid.
Only one datasource per organization can be marked as default
```

### Root Cause
Two separate Kubernetes ConfigMaps both had `isDefault: true` for different datasources, and Grafana's sidecar merged them into a single `datasource.yaml`:

1. `monitoring-kube-prometheus-grafana-datasource` — Prometheus with `isDefault: true` (from kube-prometheus-stack chart)
2. `loki-loki-stack` — Loki with `isDefault: true` (auto-created by loki-stack chart for external Grafana integration)

The loki-stack chart creates this ConfigMap even when `grafana.enabled: false` — it's designed to auto-register Loki with any Grafana that has the sidecar label `grafana_datasource=1` watching for ConfigMaps.

### Diagnosis
```bash
$ kubectl get configmap -n monitoring -l grafana_datasource=1 -o yaml | grep -A2 "isDefault\|name:"
      - name: Loki
        isDefault: true     # ← from loki-loki-stack ConfigMap
      - name: "Prometheus"
        isDefault: true     # ← from kube-prometheus-stack ConfigMap
# Two defaults — Grafana refuses to start
```

### Fix — Two parts

**Part 1: Patch the ConfigMap immediately (unblocks Grafana now)**
```bash
kubectl get configmap loki-loki-stack -n monitoring -o yaml > /tmp/loki-cm.yaml
sed -i 's/isDefault: true/isDefault: false/' /tmp/loki-cm.yaml
kubectl apply -f /tmp/loki-cm.yaml
kubectl rollout restart deployment/monitoring-grafana -n monitoring
kubectl delete pod monitoring-grafana-<old-pod-id> -n monitoring
```

**Part 2: Prevent ArgoCD from reverting the patch (permanent fix)**

In `kubernetes/argocd/loki.yaml`:
```yaml
ignoreDifferences:
  - group: ""
    kind: ConfigMap
    name: loki-loki-stack
    namespace: monitoring
    jsonPointers:
      - /data

syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true   # ← critical — without this, ArgoCD still overwrites
```

### Result
```
$ kubectl get pods -n monitoring
monitoring-grafana-5479bc5f75-r92dq   3/3   Running   0   5m
```

---

## 15. ArgoCD — ignoreDifferences Not Preventing Revert

### Symptom
We patched the `loki-loki-stack` ConfigMap to set `isDefault: false` and added `ignoreDifferences` to the ArgoCD app. But after the next reboot and ArgoCD sync, the ConfigMap reverted to `isDefault: true` and Grafana crashed again.

### Root Cause
`ignoreDifferences` without `RespectIgnoreDifferences=true` in syncOptions is **display-only**. It tells ArgoCD not to show the field as a diff in the UI, but ArgoCD still **applies** the chart-rendered version of the resource during sync — which overwrites our manual patch.

`RespectIgnoreDifferences=true` is the additional flag that makes ArgoCD actually **skip applying** the ignored fields during sync operations.

### Fix
```yaml
# In kubernetes/argocd/loki.yaml
ignoreDifferences:
  - group: ""
    kind: ConfigMap
    name: loki-loki-stack
    namespace: monitoring
    jsonPointers:
      - /data

syncPolicy:
  syncOptions:
    - CreateNamespace=false
    - ServerSideApply=true
    - RespectIgnoreDifferences=true  # ← this makes ignoreDifferences actually work for syncs
```

---

## 16. AlertManager — undefined receiver "null" used in route

### Symptom
```
# Prometheus Operator logs:
$ kubectl logs -n monitoring deployment/monitoring-kube-prometheus-operator --tail=10
level=error msg="Unhandled Error" err="sync failed: provision alertmanager configuration:
failed to initialize from secret: undefined receiver \"null\" used in route"

# AlertManager StatefulSet never created:
$ kubectl get statefulset -n monitoring
# alertmanager StatefulSet missing
```

### Root Cause
The kube-prometheus-stack chart ships with a default AlertManager configuration that includes a `Watchdog` heartbeat alert routed to a receiver named `null`. When we provided our own `alertmanager.config` in the Helm values, we replaced the entire default config — but forgot to include the `null` receiver definition. The Prometheus Operator validates the config before creating the StatefulSet and rejects it because a route references a receiver (`null`) that doesn't exist.

### Fix
Add the `null` receiver and route `Watchdog`/`InfoInhibitor` to it:
```yaml
alertmanager:
  config:
    route:
      receiver: 'gmail'
      routes:
        - receiver: 'null'
          matchers:
            - alertname =~ "Watchdog|InfoInhibitor"

    receivers:
      - name: 'null'    # accepts alerts and discards them — no notification sent
      - name: 'gmail'
        email_configs:
          - to: 'alerts@example.com'
            send_resolved: true
```

### Result
```
$ kubectl get statefulset -n monitoring
alertmanager-monitoring-kube-prometheus-alertmanager   1/1   Running   0   2m

$ kubectl get pods -n monitoring | grep alertmanager
alertmanager-monitoring-kube-prometheus-alertmanager-0   2/2   Running   0   3m
```

---

## 17. Node Memory Exhaustion — Full Cluster Freeze

### Symptom
```
# kubectl times out completely
$ kubectl get pods
Unable to connect to the server: net/http: TLS handshake timeout

# SSH hangs
$ ssh -i ~/.ssh/cloudcommerce-dev-key ubuntu@63.184.235.88
# (cursor blinks, no response, no timeout)

# Browser — Grafana/AlertManager not loading
ERR_CONNECTION_TIMED_OUT
```

### Root Cause
Multiple factors compounded:
1. Node was already at 87% actual memory usage (monitoring stack + 12 microservices)
2. Grafana entered CrashLoopBackOff — each restart cycle consumed extra CPU/memory (not idle)
3. ArgoCD sync during AlertManager installation launched multiple pods simultaneously
4. OS started swapping — everything slowed including the k3s API server itself
5. API server couldn't complete TLS handshakes → kubectl times out
6. sshd process starved of CPU → SSH hangs

### Troubleshooting Methodology
**Rule:** If both kubectl AND SSH are unresponsive, the issue is the underlying OS/hardware — not Kubernetes, not networking. The control plane and the worker node are the same machine (single-node cluster). When the node drowns, everything goes with it.

**Key insight:** A CrashLoopBackOff pod is NOT idle. It's restarting every 60-90 seconds, consuming resources on each attempt. In our case, Grafana was crashing 8+ times — actively worsening the memory pressure it was supposed to monitor.

### Fix
AWS Console → EC2 → Instances → your k3s instance → **Reboot**

After reboot (~2-3 minutes):
```bash
# Fix kubeconfig permissions (they reset on reboot)
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# Verify everything came back
kubectl get pods --all-namespaces
```

### Why GitOps Makes This Safe
On a traditional server, rebooting means manually restarting services, checking configs, recovering state. With GitOps:
- ArgoCD re-syncs all applications from Git automatically
- All 12 boutique pods restart
- Prometheus, Grafana, Loki, AlertManager all come back
- Zero manual intervention required

The reboot is safe **because** everything is defined in Git. The node is ephemeral — the truth is in Git.

---

## 18. git push Rejected — Jenkins Pushed First

### Symptom
```
$ git push
To https://github.com/Dennis4507/cloudcommerce-devops.git
 ! [rejected]        main -> main (non-fast-forward)
error: failed to push some refs to 'https://github.com/Dennis4507/cloudcommerce-devops.git'
hint: Updates were rejected because the remote contains work that you do not have locally.
hint: Integrate the remote changes (e.g. 'git pull ...') before pushing again.
```

### Root Cause
Jenkins automatically commits to the `cloudcommerce-devops` repo when it updates `values.yaml` with new image tags. If Jenkins committed and pushed while you were working locally, your local branch is behind the remote. Git rejects pushes that aren't fast-forward (linear history).

### Troubleshooting Methodology
"Non-fast-forward" means someone else pushed after your last pull. Always check `git log origin/main` to see what the remote has. In a CI/CD system, Jenkins is a "collaborator" on the repo — you need to integrate its commits before pushing yours.

### Fix
```bash
# Pull remote commits and replay your local commits on top
git pull --rebase

# Then push — now your commits are on top of Jenkins' commits
git push
```

### Why `--rebase` not `--merge`
`git pull` without `--rebase` creates a merge commit: "Merged remote-tracking branch 'origin/main'". This pollutes the history with empty merge commits that don't mean anything.

`git pull --rebase` replays your local commits on top of the remote commits — history stays linear and readable:
```
# With --rebase (clean):
Jenkins: ci: update values.yaml image tag [skip ci]
You:     feat: add new feature

# With merge (messy):
You:     Merge remote-tracking branch 'origin/main'
Jenkins: ci: update values.yaml image tag [skip ci]
You:     feat: add new feature
```

In large teams with CI/CD pipelines, `--rebase` is the standard.

---

## 19. ECR Token Expiry — ImagePullBackOff After 12 Hours

### Symptom
```
$ kubectl get pods -n online-boutique
NAME                        READY   STATUS             RESTARTS   AGE
adservice-65bbd8bf4d-rsnf6  0/1     ImagePullBackOff   0          21m
cartservice-567946bd8d      0/1     ErrImagePull       0          21m
```

Pods were running fine, then after a rolling update triggered by a Jenkins build, new pods fail to pull images. Older pods (already running) are unaffected — they use cached images.

### Root Cause
ECR authentication tokens expire after **12 hours**. The Ansible playbook writes the token to `/etc/rancher/k3s/registries.yaml` at setup time — but never refreshes it. Containerd (k3s's container runtime) uses this static token for all image pulls. After 12 hours, ECR rejects the expired token.

This only becomes visible during rolling updates — existing pods use cached images and don't need to re-pull. New pods (new image tag) must pull from ECR and hit the expired token.

### Troubleshooting Methodology
When `ImagePullBackOff` appears on new pods but old pods are Running:
1. It's an authentication issue, not a code issue
2. Check if the ECR token is expired: `sudo cat /etc/rancher/k3s/registries.yaml | head -5`
3. Check when the token was last refreshed — if more than 12 hours ago, it's expired

### Immediate Fix — Refresh from WSL
```bash
# Generate fresh token on WSL (AWS CLI is installed here, not on k3s server)
TOKEN=$(aws ecr get-login-password --region eu-central-1 --profile cloudcommerce)
ACCOUNT=$(aws sts get-caller-identity --profile cloudcommerce --query Account --output text)

# Write to k3s server via SSH and restart k3s
ssh -i ~/.ssh/cloudcommerce-dev-key ubuntu@63.184.235.88 "
sudo bash -c 'cat > /etc/rancher/k3s/registries.yaml << EOF
configs:
  \"${ACCOUNT}.dkr.ecr.eu-central-1.amazonaws.com\":
    auth:
      username: \"AWS\"
      password: \"${TOKEN}\"
EOF'
sudo systemctl restart k3s
echo Done"
```

### Permanent Fix — Cron Job via Ansible
Added to `ansible/playbooks/setup-k3s.yml`:
```yaml
- name: Create ECR token refresh script
  copy:
    dest: /usr/local/bin/refresh-ecr-token.sh
    mode: '0755'
    content: |
      #!/bin/bash
      REGION="eu-central-1"
      ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
      TOKEN=$(aws ecr get-login-password --region ${REGION})
      cat > /etc/rancher/k3s/registries.yaml << EOF
      configs:
        "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com":
          auth:
            username: "AWS"
            password: "${TOKEN}"
      EOF
      systemctl restart k3s
      echo "$(date '+%Y-%m-%d %H:%M:%S') - ECR token refreshed" >> /var/log/ecr-refresh.log

- name: Add cron job to refresh ECR token every 6 hours
  cron:
    name: "Refresh ECR token for k3s containerd"
    minute: "0"
    hour: "*/6"
    job: "/usr/local/bin/refresh-ecr-token.sh >> /var/log/ecr-refresh.log 2>&1"
    user: root
```

The script uses the EC2 IAM instance profile — no credentials stored anywhere.

### Proof it works
```
$ cat /var/log/ecr-refresh.log
2026-06-03 14:42:48 - ECR token refreshed  ← Ansible playbook
2026-06-03 18:00:22 - ECR token refreshed  ← AUTOMATIC CRON (18:00)
2026-06-03 18:56:08 - ECR token refreshed  ← manual test
```
The 18:00:22 entry was the cron job firing automatically. The token will never expire unattended.

### Result
```
$ kubectl get pods -n online-boutique
NAME                                  READY   STATUS    RESTARTS   AGE
adservice-65bbd8bf4d-kmmmd            1/1     Running   0          9m
cartservice-567946bd8d-fhdgc          1/1     Running   0          9m
# All 12 services Running — image pulls succeeding with fresh token
```

---

## 20. CPU Requests at 100% — Rolling Update Deadlock on Single Node

### Symptom
```
$ kubectl get pods -n online-boutique
NAME                         READY   STATUS    AGE
adservice-old-gen            1/1     Running   10d   ← old pods running
adservice-new-gen            0/1     Pending   6h    ← new pods stuck Pending

$ kubectl describe pod adservice-new-gen -n online-boutique
Events:
  Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient cpu.
  no new claims to deallocate, preemption: 0/1 nodes are available:
  1 No preemption victims found for incoming pod.

$ kubectl describe node | grep -A 5 "Allocated resources"
  cpu     2000m (100%)   3675m (183%)   ← node at 100% CPU requests
  memory  2520Mi (32%)   4400Mi (56%)   ← memory fine — cpu is the problem
```

New pods stuck Pending for 6+ hours. Old pods Running but outdated. Rolling update completely deadlocked.

### Root Cause
**CPU Requests ≠ CPU Usage.** Requests are what Kubernetes reserves for scheduling. Actual usage was ~15%, but requests were at 100%.

The chart values copied from Google's production environment set requests of 100-200m per service — designed for multi-node clusters where these requests distribute across many nodes. On a single node:

```
11 services × ~140m avg = 1540m requests
Monitoring stack:          ~400m requests
ArgoCD + system:           ~300m requests
Total:                     ~2240m > 2000m (already over before rolling update)

During rolling update (both generations):
1540m × 2 = 3080m for boutique alone → impossible on 2000m node
```

Rolling update rule: "Don't terminate old pod until new pod is Running." New pod can't start (no CPU request headroom). Old pod won't terminate (waiting for new pod). Permanent deadlock.

### Troubleshooting Methodology
```bash
# Step 1 — confirm scheduling failure
kubectl describe pod <pending-pod> -n online-boutique | tail -10
# Look for: "Insufficient cpu" or "Insufficient memory"

# Step 2 — check node allocation
kubectl describe node | grep -A 8 "Allocated resources"
# Look at Requests percentage — if >80%, rolling updates will struggle

# Step 3 — compare requests vs actual usage in Grafana
# Dashboard: Kubernetes → Compute Resources → Cluster
# Compare CPU Requests column vs CPU Usage column
# If requests >> usage, right-size the requests
```

### Fix
Reduce CPU requests in `kubernetes/apps/online-boutique/values.yaml` based on observed Prometheus metrics:

```yaml
# Before — production values designed for multi-node clusters
adService:
  resources:
    requests:
      cpu: 200m   # reserved 200m, actually using ~5m

# After — right-sized for single-node, matches observed usage
adService:
  resources:
    requests:
      cpu: 50m    # still far above actual usage (~5m), but leaves room for rolling updates
    limits:
      cpu: 300m   # unchanged — pod can still burst to full CPU when needed
```

Limits were left unchanged. Limits define the ceiling; requests define the floor for scheduling.

After the change, one manual pod delete of the old generation was needed to break the deadlock (old pods had the old high requests in their spec — those don't change until pods are replaced):

```bash
kubectl delete pod -n online-boutique \
  adservice-<old-hash> cartservice-<old-hash> ...  # all old Running pods
```

This freed the old reservations. New pods with lower requests scheduled immediately.

### Result
```
$ kubectl describe node | grep -A 5 "Allocated resources"
  cpu     1100m (55%)   3675m (183%)   ← now has headroom for rolling updates
  memory  2520Mi (32%)  4400Mi (56%)

$ kubectl get pods -n online-boutique
# Single generation, all 12 Running — rolling updates work automatically going forward
```

### Why This Matters
Setting requests equal to limits (or to arbitrary "safe" values) is a common mistake. In a team environment, requests should be set based on observed p95 usage from production metrics — not guesses. Prometheus provides this data; the Grafana dashboard makes it visible. The fix was data-driven: Prometheus showed 15% actual CPU vs 100% reserved. The requests were reduced to match reality.

---

## 21. Grafana CrashLoopBackOff — Two isDefault Datasources (Permanent Fix)

### Symptom
```
$ kubectl get pods -n monitoring | grep grafana
monitoring-grafana-5479bc5f75-mfdms   2/3   CrashLoopBackOff   124 (2m13s ago)   3d5h

$ kubectl logs -n monitoring monitoring-grafana-5479bc5f75-mfdms -c grafana --tail=5
logger=provisioning level=error msg="Failed to provision data sources"
error="Only one datasource per organization can be marked as default"
```

Grafana crashed 124 times over 3 days. Manual ConfigMap patches kept reverting.

### Root Cause
The loki-stack Helm chart creates a ConfigMap called `loki-loki-stack` with `isDefault: true` — even when `grafana.enabled: false`. This ConfigMap is intended for external Grafana instances to auto-detect Loki.

Meanwhile, kube-prometheus-stack also sets Prometheus as `isDefault: true`. Grafana's sidecar merges all ConfigMaps with label `grafana_datasource=1` into a single datasources file. Two `isDefault: true` values → crash.

The previous fix (manual ConfigMap patch + `ignoreDifferences`) failed because `RespectIgnoreDifferences=true` was missing from ArgoCD syncOptions — so ArgoCD applied the chart-rendered version during sync, reverting the patch.

### Diagnosis
```bash
# Find all ConfigMaps that Grafana's sidecar will pick up
kubectl get configmap -n monitoring -l grafana_datasource=1 -o yaml | grep "isDefault"
# isDefault: true   ← loki-loki-stack ConfigMap
# isDefault: true   ← prometheus ConfigMap
# Two defaults → crash

# Check which version of RespectIgnoreDifferences is in the ArgoCD app
kubectl get application loki -n argocd -o yaml | grep -A5 "syncOptions"
```

### Fix — Disable the ConfigMap at Source

The cleanest fix: stop loki-stack from creating the conflicting ConfigMap at all. Since Loki is already registered as a datasource via `additionalDataSources` in kube-prometheus-stack, the loki-stack ConfigMap is redundant.

```yaml
# kubernetes/monitoring/loki-stack-values.yaml
grafana:
  enabled: false
  sidecar:
    datasources:
      enabled: false  # ← prevents loki-loki-stack ConfigMap from being created
```

Delete the old ConfigMap manually, then ArgoCD syncs the updated loki values — the ConfigMap is gone permanently:

```bash
kubectl delete configmap loki-loki-stack -n monitoring
kubectl delete pod -n monitoring <grafana-pod>  # restart with clean slate
```

### Result
```
$ kubectl get pods -n monitoring | grep grafana
monitoring-grafana-5479bc5f75-4zvm4   3/3   Running   0   74m
# 0 restarts — Grafana starts cleanly and stays running
```

### Why the Previous Fix Didn't Hold
| Approach | Why It Failed |
|----------|--------------|
| Manual ConfigMap patch | ArgoCD reverted it on next sync |
| ignoreDifferences (without RespectIgnoreDifferences) | Display-only — ArgoCD still applied chart values during sync |
| ignoreDifferences + RespectIgnoreDifferences | Prevented reversion — but ConfigMap still existed with potential to conflict |
| Disable sidecar.datasources ← this fix | ConfigMap never created — nothing to conflict |

The root fix disables the source of the conflict rather than patching its output.

---

## General Troubleshooting Methodology

### The Diagnostic Ladder

When something isn't working, work from the outside in:

```
1. Can I reach the machine?          → ping, SSH
2. Is the process running?           → systemctl status, kubectl get pods
3. What is the process saying?       → kubectl logs, journalctl
4. What does the resource look like? → kubectl describe, kubectl get -o yaml
5. What do events say?               → kubectl describe (Events section at bottom)
6. What is the node doing?           → kubectl describe node, kubectl top
```

Never skip steps. The most common mistake is jumping to conclusions and making changes before understanding the root cause.

### Key Commands for Any Kubernetes Issue

```bash
# What's the status of everything?
kubectl get pods --all-namespaces

# Why is this pod not running?
kubectl describe pod <pod-name> -n <namespace>
# Look at: Events section at the bottom — this is where the real error is

# What is the pod logging?
kubectl logs <pod-name> -n <namespace> --tail=30
kubectl logs <pod-name> -n <namespace> -c <container-name> --tail=30  # multi-container pod

# Is it a resource problem?
kubectl describe node | grep -A 8 "Allocated resources"

# What does the actual resource spec look like (vs what I think it should be)?
kubectl get <resource> <name> -n <namespace> -o yaml

# Is ArgoCD seeing the right state?
kubectl get application <app-name> -n argocd -o yaml | grep -A5 "message\|status"
```

### Reading `kubectl describe pod` Events

The Events section at the bottom of `kubectl describe pod` is the most useful diagnostic output in Kubernetes. Read it before anything else:

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ---   ----               -------
  Warning  FailedScheduling  5m    default-scheduler  0/1 nodes available: Insufficient cpu
  Warning  BackOff           2m    kubelet            Back-off restarting failed container
  Normal   Pulled            1m    kubelet            Successfully pulled image
```

- `FailedScheduling` → scheduling problem (resources, taints, affinity)
- `BackOff` → container crashing repeatedly (check logs)
- `ErrImagePull` / `ImagePullBackOff` → image registry problem (auth, image name, tag)
- `OOMKilled` → container exceeded memory limit — increase the limit

---

## Command Reference — What Each Command Does and Why

Every command used in this project explained in plain language. Not just what to type — but what it's actually doing and when to reach for it.

---

### kubectl get pods

```bash
kubectl get pods -n monitoring
```

**What it does:** Lists all pods in the `monitoring` namespace with their current status.

**Breaking it down:**
- `kubectl` — the command-line tool for talking to Kubernetes
- `get pods` — fetch the list of pod objects
- `-n monitoring` — only show pods in the `monitoring` namespace (`-n` is short for `--namespace`)

**What to look at in the output:**
```
NAME                                    READY   STATUS             RESTARTS   AGE
monitoring-grafana-755c9b8db7-t5xk7     2/3     CrashLoopBackOff   8          6h
prometheus-monitoring-kube-...          2/2     Running            0          2d
```
- `READY` — how many containers are ready out of total (2/3 means one container is failing)
- `STATUS` — current state. `Running` is good. `Pending`, `CrashLoopBackOff`, `ErrImagePull` need investigation
- `RESTARTS` — how many times the pod has restarted. High numbers = it keeps crashing
- `AGE` — how long the pod has been running

**Variants:**
```bash
kubectl get pods --all-namespaces    # show pods across every namespace
kubectl get pods -n monitoring -w    # watch mode — live updates as status changes
kubectl get pods -n monitoring -o wide  # adds node name and pod IP to the output
```

---

### kubectl describe pod

```bash
kubectl describe pod monitoring-grafana-755c9b8db7-t5xk7 -n monitoring
```

**What it does:** Shows everything Kubernetes knows about a specific pod — its configuration, current state, and crucially, the **Events** log which shows exactly what happened and why.

**When to use it:** When `kubectl get pods` shows a pod isn't running. `get` tells you *what* is wrong (CrashLoopBackOff). `describe` tells you *why*.

**The most important part — Events (scroll to the bottom):**
```
Events:
  Type     Reason            Age   From               Message
  Warning  FailedScheduling  5m    default-scheduler  0/1 nodes available: Insufficient cpu
  Warning  BackOff           30s   kubelet            Back-off restarting failed container
```
Events are in chronological order. The most recent events are most relevant. `Warning` events are problems. `Normal` events are expected behaviour.

**Other useful sections:**
```
Limits:
  cpu:     100m
  memory:  128Mi
Requests:
  cpu:     50m        ← this is what Kubernetes reserved for scheduling
  memory:  64Mi

Conditions:
  Ready: False        ← pod is not ready to serve traffic
```

---

### kubectl logs

```bash
kubectl logs monitoring-grafana-755c9b8db7-t5xk7 -n monitoring -c grafana --tail=30
```

**What it does:** Reads the stdout/stderr output of a container — the same output you'd see if you ran the process in your terminal.

**Breaking it down:**
- `monitoring-grafana-755c9b8db7-t5xk7` — the pod name
- `-n monitoring` — namespace
- `-c grafana` — which container inside the pod (`-c` is for `--container`). Needed when a pod has multiple containers (Grafana has 3: grafana, grafana-sc-datasources, grafana-sc-dashboard)
- `--tail=30` — only show the last 30 lines (without this you get everything from the beginning)

**When to use it:** After `kubectl describe pod` tells you *that* a container is crashing, `kubectl logs` tells you the actual error message the application printed before it crashed.

**Variants:**
```bash
kubectl logs <pod> -n <namespace> -f              # follow mode — streams new lines in real time (like tail -f)
kubectl logs <pod> -n <namespace> --previous      # logs from the PREVIOUS run of the container (before the last crash)
kubectl logs -n monitoring -l app=grafana --tail=20  # logs from ALL pods matching a label (useful when you don't know the exact pod name)
```

**The `--previous` flag is particularly useful:** When a pod crashed and restarted, the current logs are from the new instance. The crash logs from the last run are accessed with `--previous`.

---

### kubectl describe node

```bash
kubectl describe node | grep -A 8 "Allocated resources"
```

**What it does:** Shows detailed information about the node (the EC2 instance), including how much CPU and memory has been **reserved** by pod requests vs how much is actually available.

**Breaking it down:**
- `kubectl describe node` — full node description (very long)
- `|` — pipe — sends the output of the left command as input to the right command
- `grep -A 8 "Allocated resources"` — find the line containing "Allocated resources" and show that line plus the 8 lines after it (`-A` means "after")

**What the output looks like:**
```
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                1940m (99%)   2300m (115%)
  memory             2156Mi (57%)  4356Mi (115%)
```
- `Requests` — what pods have reserved for scheduling (99% CPU = almost full)
- `Limits` — the maximum pods are allowed to use (can exceed 100% — that's overcommitting)
- The percentages are out of the node's total capacity

**Why this matters:** If `Requests` for CPU is at 99%, new pods cannot be scheduled — even if actual CPU usage is only 12%. Kubernetes uses requests for scheduling decisions, not actual usage.

---

### kubectl top

```bash
kubectl top nodes
kubectl top pods -n monitoring
```

**What it does:** Shows **actual real-time** CPU and memory usage — not reservations, but what's genuinely being consumed right now.

**Why use both `describe node` and `top`:** They answer different questions:
- `describe node` → what has been **reserved** (affects scheduling)
- `top` → what is being **used** (affects performance and OOM risk)

A node can be at 99% reserved CPU but only 12% actual usage — pods reserved defensively but aren't busy. This is exactly what we found.

**Note:** `kubectl top` requires the metrics-server to be running. In k3s it's available by default.

---

### kubectl exec

```bash
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}') \
  -c grafana \
  -- wget -qO- http://loki.monitoring.svc.cluster.local:3100/ready
```

**What it does:** Runs a command inside a running container — like SSH-ing into the container.

**Breaking it down:**
- `kubectl exec` — execute a command inside a container
- `$(kubectl get pod ... -o jsonpath=...)` — a subcommand that finds the pod name dynamically (so you don't have to look it up manually)
- `-c grafana` — which container inside the pod
- `--` — separates kubectl arguments from the command being run inside the container
- `wget -qO- http://loki...:3100/ready` — the command to run inside the container

**Why we used this:** When Grafana couldn't connect to Loki, we needed to know if the problem was network connectivity or just a wrong URL. Running `wget` from *inside* the Grafana container tests the connection from Grafana's perspective (same network namespace, same DNS resolution). The result `ready` confirmed Loki was reachable — the URL was just wrong.

**Simpler example:**
```bash
# Open a shell inside a pod (like SSH)
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Run a single command
kubectl exec <pod-name> -n <namespace> -- cat /etc/config/something.yaml
```

---

### kubectl get -o yaml / -o jsonpath

```bash
# Get the full resource definition as YAML
kubectl get pod loki-0 -n monitoring -o yaml

# Extract a specific field
kubectl get pod loki-0 -n monitoring -o jsonpath='{.spec.containers[0].resources}'
```

**What it does:** Instead of the formatted table output, returns the raw Kubernetes object. This shows the actual state stored in Kubernetes — including fields that aren't shown in the default table view.

**When to use `-o yaml`:** When you need to verify the actual configuration. For example, we checked the pod spec to confirm whether `cpu: null` had actually been applied by looking at the real resources field.

**When to use `-o jsonpath`:** When you only need one specific field. `jsonpath` lets you navigate the JSON structure and extract just the value you want:
```bash
# Get just the image tag
kubectl get pod frontend-xxx -n online-boutique -o jsonpath='{.spec.containers[0].image}'

# Get the revision ArgoCD synced to
kubectl get application monitoring -n argocd -o jsonpath='{.status.sync.revision}'
```

---

### kubectl delete pod

```bash
kubectl delete pod monitoring-grafana-755c9b8db7-t5xk7 -n monitoring
```

**What it does:** Deletes the pod. Kubernetes immediately creates a replacement.

**Why deleting a pod is safe:** Pods are ephemeral by design. A Deployment (or StatefulSet) maintains a desired number of replicas. When you delete a pod, the controller notices it's gone and creates a new one. The new pod is freshly created — a clean slate.

**When to use it:**
- Pod is in CrashLoopBackOff and the underlying issue is fixed — delete to get a clean restart
- Rolling update deadlock — old pod holding resources, delete it to unblock the new one
- Pod is stuck in a bad state that normal restart backoff won't clear

**What you should NOT do:** Delete a pod expecting the problem to go away without fixing the root cause. If the application is crashing due to a config bug, the new pod will crash too.

---

### kubectl delete statefulset

```bash
kubectl delete statefulset loki -n monitoring
```

**What it does:** Deletes the StatefulSet controller AND its pods. ArgoCD recreates it from Git on the next sync.

**This is more drastic than deleting a pod** — you're removing the controller itself, not just one instance. Use it when:
- The StatefulSet template has been updated but a stuck Pending pod won't pick up the changes (rolling update skips non-Running pods)
- You need the controller to be recreated from scratch with a fresh template

**Why it's safe with ArgoCD:** ArgoCD manages the StatefulSet. When it detects the StatefulSet is missing (drift from Git), it recreates it within 3 minutes using the current Git state. Nothing is permanently lost — Git is the truth.

---

### kubectl rollout restart

```bash
kubectl rollout restart deployment/monitoring-grafana -n monitoring
```

**What it does:** Triggers a rolling restart of all pods in a Deployment — one by one, gracefully. It's the correct way to restart a Deployment without downtime.

**Why not just delete the pod?** `delete pod` restarts one pod immediately. `rollout restart` updates the Deployment template (adds an annotation with a timestamp), which triggers a proper rolling update — new pod created, old pod terminated only after new one is ready.

**When to use it:**
- After patching a ConfigMap that Grafana reads at startup — restart so it picks up the new config
- After updating a Secret that's mounted in the pods
- When pods need a clean restart but you want it done gracefully

---

### kubectl annotate (Force ArgoCD Refresh)

```bash
kubectl annotate application monitoring -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

**What it does:** Adds (or updates) an annotation on an ArgoCD Application object. ArgoCD watches for this specific annotation and treats it as a signal to immediately re-fetch the Git repository and recompute the desired state.

**Breaking it down:**
- `kubectl annotate` — add/update annotations on a Kubernetes resource
- `application monitoring` — the ArgoCD Application named "monitoring"
- `-n argocd` — it lives in the argocd namespace
- `argocd.argoproj.io/refresh=hard` — the specific annotation ArgoCD watches (hard = also refresh the Helm chart cache)
- `--overwrite` — if the annotation already exists, update it (without this, it errors if the annotation is present)

**When to use it:** When ArgoCD shows "Synced" but you just pushed a change and expect it to re-sync. Normally ArgoCD polls Git every 3 minutes. This forces an immediate refresh without waiting.

---

### grep -A, -B, -C

```bash
kubectl describe node | grep -A 8 "Allocated resources"
kubectl get application monitoring -n argocd -o yaml | grep -A5 "message\|status"
```

**What it does:** Searches for a pattern in text and shows surrounding lines.

**The flags:**
- `-A 8` — show **A**fter: the matching line plus 8 lines below it
- `-B 5` — show **B**efore: the matching line plus 5 lines above it
- `-C 3` — show **C**ontext: 3 lines above AND below (combines -A and -B)

**Why use it:** `kubectl describe node` output is hundreds of lines long. You only care about one section. `grep -A 8 "Allocated resources"` jumps directly to that section and shows it with enough context to be useful.

**The `\|` in grep:**
```bash
grep -A5 "message\|status"
```
`\|` means OR in grep — match lines containing "message" OR "status". Shows both in one command.

---

### sed -i (In-place text substitution)

```bash
sed -i 's/isDefault: true/isDefault: false/' /tmp/loki-cm.yaml
```

**What it does:** Edits a file in place — finds text and replaces it, saving the result back to the same file.

**Breaking it down:**
- `sed` — stream editor (processes text line by line)
- `-i` — **i**n-place editing (modifies the file directly, not just prints to terminal)
- `'s/isDefault: true/isDefault: false/'` — substitution command:
  - `s` — substitute
  - `/isDefault: true/` — find this pattern
  - `/isDefault: false/` — replace with this
  - The final `/` closes the command
- `/tmp/loki-cm.yaml` — the file to edit

**Why we used it:** We needed to change one value in a Kubernetes ConfigMap YAML without opening a text editor. We exported the ConfigMap to a file, used `sed` to swap the value, then re-applied the file. Quick surgical change.

---

### kubectl get statefulset / deployment / all

```bash
kubectl get statefulset -n monitoring
kubectl get deployment -n monitoring
kubectl get all -n monitoring
```

**What they do:** List specific types of Kubernetes objects.

- `get statefulset` — lists StatefulSets (ordered, stable-identity pods like databases, Loki, Prometheus)
- `get deployment` — lists Deployments (stateless pods like Grafana, Jenkins)
- `get all` — lists everything in the namespace: pods, services, deployments, replicasets, statefulsets

**The READY column:**
```
NAME                                                   READY   AGE
alertmanager-monitoring-kube-prometheus-alertmanager   1/1     31m
loki                                                   0/1     26h   ← 0 replicas ready out of 1 expected
```
`0/1` means the StatefulSet wants 1 pod running but has 0 ready. Always investigate.

---

### The Pipe `|` — Chaining Commands

Used constantly in troubleshooting:
```bash
kubectl describe node | grep -A 8 "Allocated resources"
kubectl logs -n monitoring deployment/monitoring-kube-prometheus-operator | grep error
```

**What it does:** Takes the output of the command on the left and feeds it as input to the command on the right.

Think of it as: "do this, then do that with the result."

Without the pipe you'd have to:
1. Run `kubectl describe node` → thousands of lines scroll by
2. Manually scroll to find "Allocated resources"

With the pipe, `grep` does the searching for you instantly.

---

### $() — Command Substitution

```bash
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://loki:3100/ready
```

**What it does:** The `$(...)` runs the inner command first and substitutes its output into the outer command.

So `$(kubectl get pod ... -o jsonpath='...')` runs `kubectl get pod` to find the pod name, then that name is inserted into the `kubectl exec` command. You don't have to know the pod name in advance — the command finds it for you.

**Why this matters:** Pod names have random suffixes (`monitoring-grafana-755c9b8db7-t5xk7`). Every time a pod restarts it gets a new suffix. Command substitution lets you reference pods dynamically without having to type the full name.

---

### git pull --rebase

```bash
git pull --rebase
git push
```

**What it does:** Fetches remote commits (from GitHub), then **replays your local commits on top** of the remote commits — keeping history linear.

**The difference from regular `git pull`:**

Regular `git pull` (which does a merge):
```
A --- B --- C (remote: Jenkins commit)
      \
       D --- E (your local commits)
              \
               Merge commit (messy — extra commit that says nothing)
```

`git pull --rebase`:
```
A --- B --- C (remote: Jenkins commit)
                \
                 D' --- E' (your commits replayed on top — clean history)
```

**When to use it:** Any time your push is rejected because the remote has commits you don't have locally. In this project, Jenkins commits automatically to update image tags. When you push your own changes, Jenkins may have pushed first. `--rebase` integrates Jenkins' commits cleanly.

**[skip ci] in commit messages:** When Jenkins or scripts commit automatically (like updating `values.yaml` with new image tags), adding `[skip ci]` to the commit message tells Jenkins not to trigger a new pipeline build for that commit. Without it, Jenkins would trigger a build → push a new commit → trigger another build → infinite loop.
