# kubectl, Kubeconfig, WSL Paths, and the x509 Problem — Deep Dive

## The Problem We Ran Into

After rebuilding the k3s server, `kubectl get nodes` kept returning:

```
x509: certificate signed by unknown authority
```

We copied the kubeconfig from the server multiple times. The error never went away. This document explains why — and everything you need to understand it fully.

---

## What is WSL?

WSL (Windows Subsystem for Linux) is a full Linux computer running **inside** your Windows laptop. It is not a virtual machine and not a separate physical computer — it shares your CPU, RAM, and hard drive. But it has its own filesystem, its own home folder, and its own way of naming files.

So your laptop has **two operating systems living side by side:**

```
Your laptop
├── Windows   →  C:\Users\OnlyM\...
└── WSL/Ubuntu →  /home/denis/...
```

You switch between them depending on where you open a terminal:
- Open PowerShell → you are in Windows
- Open WSL/Ubuntu → you are in Linux

---

## What is /mnt/c/?

WSL can read and write Windows files — but it uses a different address to get to them.

```
Windows address:   C:\Users\OnlyM\Documents
WSL address:       /mnt/c/Users/OnlyM/Documents
```

`/mnt/c/` is WSL's doorway into your Windows C: drive. The files are **exactly the same** — just two different names for the same location on disk.

Think of it like a building with two entrances:
- The front door (Windows): `C:\Users\OnlyM\`
- The back door (WSL): `/mnt/c/Users/OnlyM/`

Both doors lead to the same room.

---

## What is ~ in WSL?

`~` is shorthand for "my home folder." Every Linux user has a home folder — a personal space for their files and settings.

In WSL, your home folder is:

```
/home/denis/
```

So whenever you type `~` inside WSL, Linux replaces it with `/home/denis/`:

```
~/.kube/config  →  /home/denis/.kube/config
~/k3s-fresh.yaml  →  /home/denis/k3s-fresh.yaml
```

**Important:** This `/home/denis/` folder is **WSL-only**. Windows cannot see it. It lives inside the WSL Linux filesystem, not on your Windows C: drive.

---

## The Two Separate .kube/config Files

This is the root of the entire x509 problem. There were **two completely separate kubeconfig files** on the laptop:

```
File 1 — Windows kubeconfig:
  Windows sees it as:   C:\Users\OnlyM\.kube\config
  WSL sees it as:       /mnt/c/Users/OnlyM/.kube/config
  (same file, two different addresses)

File 2 — WSL kubeconfig:
  WSL sees it as:       /home/denis/.kube/config
  Windows cannot see this file — it only exists in WSL
```

These two files are **completely independent**. Changing one does not change the other.

---

## What is the KUBECONFIG Environment Variable?

An environment variable is a setting stored in memory that programs read when they start. `KUBECONFIG` is the setting that tells kubectl: **"this is where your config file is — go read it from here."**

When we ran:

```bash
echo $KUBECONFIG
```

The output was:

```
/mnt/c/Users/OnlyM/.kube/config
```

That is **File 1** — the Windows kubeconfig. So kubectl was always reading from Windows.

---

## Why Our Copies Were Invisible to kubectl

Every time we copied the fresh kubeconfig from the server, we ran:

```bash
cp ~/k3s-fresh.yaml ~/.kube/config
```

`~` = `/home/denis/` → this writes to **File 2** (WSL).

But `KUBECONFIG` told kubectl to read **File 1** (Windows).

```
We wrote to:       /home/denis/.kube/config          ← WSL (File 2)
kubectl read from: /mnt/c/Users/OnlyM/.kube/config   ← Windows (File 1)
```

kubectl never saw any of our copies. It kept reading the old stale Windows file every single time.

---

## What is the Kubeconfig File?

The kubeconfig is an **access card** for kubectl. It is a YAML file containing everything kubectl needs to connect to a Kubernetes cluster:

```
kubeconfig
├── 1. Where is the cluster?
│       server: https://63.184.235.88:6443
│
├── 2. Do I trust the server's identity?
│       certificate-authority-data: (the cluster's CA certificate)
│       This is used to verify the server is who it claims to be
│
└── 3. Who am I? Prove it.
        client-certificate-data: (your identity certificate)
        client-key-data: (your private key — proves the cert is yours)
```

All three parts must be correct for kubectl to connect.

---

## What is a CA Certificate and Why Did It Cause x509 Errors?

CA stands for Certificate Authority. It is a master certificate that is used to sign and verify other certificates.

When k3s is installed, it creates:
- Its own CA certificate (the master)
- A server TLS certificate signed by that CA (proves the server's identity)
- Client certificates signed by that CA (proves your identity)

The kubeconfig contains the CA certificate. When kubectl connects, it uses that CA to verify the server:

```
kubectl connects to https://63.184.235.88:6443
    ↓
k3s server sends its TLS certificate
    ↓
kubectl checks: was this server certificate signed by the CA in my kubeconfig?
    ↓
Yes → I trust this server, continue
No  → x509: certificate signed by unknown authority → connection refused
```

**What went wrong:** When the Terraform incident destroyed and rebuilt the k3s server, k3s generated a **brand new CA and brand new certificates**. The old Windows kubeconfig still had the old CA — which had nothing to do with the new server's certificates. Mismatch every time.

---

## The Fix

Copy the fresh kubeconfig to where kubectl is actually looking:

```bash
cp ~/k3s-fresh.yaml /mnt/c/Users/OnlyM/.kube/config
```

This writes to **File 1** — the Windows kubeconfig — which is exactly what `KUBECONFIG` was pointing at. kubectl read the fresh CA and fresh client credentials, verified the server successfully, and connected immediately.

---

## How kubectl Connects to k3s — Step by Step

```
You type: kubectl get nodes
        ↓
kubectl reads KUBECONFIG → finds the config file path
        ↓
Opens HTTPS connection to https://63.184.235.88:6443
        ↓
k3s server sends its TLS certificate
        ↓
kubectl checks the certificate against the CA in kubeconfig
        ↓
Match → kubectl sends its own client certificate (proves identity)
        ↓
k3s checks: is this client certificate signed by my CA?
        ↓
Yes → kubectl is authenticated → k3s sends back the list of nodes
        ↓
You see: ip-10-0-1-23   Ready   control-plane
```

kubectl is just the **remote control**. It lives on your laptop. The actual cluster (nodes, pods, containers) lives entirely on the AWS EC2 server at `63.184.235.88`. kubectl talks to it over HTTPS on port 6443.

---

## How This Connects to the Full Pipeline

Now that kubectl can reach the cluster, the full automated pipeline can run:

```
1. You push code to GitHub (microservices-demo)
        ↓
2. GitHub webhook triggers Jenkins automatically
        ↓
3. Jenkins builds the Docker image
   tags it with your commit ID: e0cacb0c
        ↓
4. Jenkins pushes the image to AWS ECR
   cloudcommerce/frontend:e0cacb0c
        ↓
5. Jenkins updates values.yaml in cloudcommerce-devops
   sets tag: "e0cacb0c"
   commits with [skip ci] to avoid triggering itself again
        ↓
6. ArgoCD (running as a pod inside k3s) watches cloudcommerce-devops on GitHub
   detects the new commit from Jenkins
        ↓
7. ArgoCD reads values.yaml → sees tag: "e0cacb0c"
   tells the k3s API: deploy this image
        ↓
8. k3s passes the instruction to containerd (its built-in container runtime)
   "pull cloudcommerce/frontend:e0cacb0c from ECR and run it"
        ↓
9. containerd pulls the image from ECR
   The k3s EC2 instance has an IAM role that gives it permission to pull from ECR
   No Docker needed — containerd talks directly to ECR
        ↓
10. containerd starts the container as a running pod inside k3s
        ↓
11. Online Boutique frontend is live
```

### Where kubectl fits in your day-to-day work

kubectl does not run any of the above automatically. The pipeline above is fully automated. kubectl is what **you** use to check on things:

```bash
kubectl get nodes          # is the cluster healthy?
kubectl get pods -A        # are all containers running?
kubectl get svc            # what services are exposed?
kubectl logs <pod-name>    # what is a specific container printing?
```

All of these commands go from your laptop → over HTTPS → to `63.184.235.88:6443` → the k3s API server reads the cluster state and sends it back.

---

## Summary — The Three-Layer Problem

The x509 error had three separate causes that looked identical from the outside:

| Layer | Problem | How We Found It | Fix |
|---|---|---|---|
| 1 | `--tls-san` missing — public IP not in server cert | Error said "cert is valid for 10.x.x.x, not 63.184.x.x" | Updated Ansible playbook to add `--tls-san 63.184.235.88` |
| 2 | Stale CA cert — old kubeconfig after server rebuild | Reinstalled k3s, copied fresh kubeconfig, still failed | Investigated further |
| 3 | Wrong file — KUBECONFIG pointed at Windows path, we kept copying to WSL | `echo $KUBECONFIG` revealed `/mnt/c/...` path | Copied to `/mnt/c/Users/OnlyM/.kube/config` |

**The lesson:** Always run `echo $KUBECONFIG` before debugging kubeconfig issues. If it points somewhere unexpected, every copy you make goes to the wrong place and the problem never goes away.

---

## Interview Talking Points

- "WSL has its own filesystem separate from Windows — files in `/home/denis/` are invisible to Windows and vice versa, unless you use the `/mnt/c/` bridge path"
- "The `KUBECONFIG` environment variable tells kubectl exactly which file to read — if it points at a Windows path and you keep copying to a WSL path, kubectl silently ignores every copy"
- "The x509 `certificate signed by unknown authority` error means the CA cert in your kubeconfig doesn't match the CA that signed the server's certificate — this happens when k3s is rebuilt because it generates a completely new CA"
- "kubectl is only a remote control — it sends commands to the Kubernetes API server over HTTPS on port 6443. All actual work (pulling images, running containers) happens on the cluster server itself"
- "ArgoCD watches the Git repository for changes to values.yaml — when Jenkins pushes a new image tag, ArgoCD detects the commit and instructs containerd to pull the new image from ECR. The pipeline is fully automated from code push to running pod"
