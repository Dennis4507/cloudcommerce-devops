# Post 03 — CrashLoopBackOff Death Spiral

---

I assumed a crashing pod wasn't doing anything.

I was wrong. And that assumption made everything worse.

📸 `docs/screenshots/193-grafana-crashloopbackoff.png`
*— Lead thumbnail. Grafana pod showing 2/3 CrashLoopBackOff with 8 restarts, other pods running fine around it. The contrast tells the story instantly — one bad pod in a sea of green.*

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, 12-microservice ecommerce app, Prometheus + Grafana + Loki + AlertManager observability stack. During setup, Grafana entered CrashLoopBackOff due to a datasource config conflict.

I had other things to fix first. I left it.

Here's what I didn't realise:

A pod in CrashLoopBackOff is not idle. Kubernetes restarts it every 60-90 seconds. Every restart cycle:
- Pulls container layers (CPU + network)
- Initialises the process until it crashes
- Reports the crash to the API server
- Waits for backoff, then repeats

Grafana crashed 8+ times while I was working on other fixes. Each crash consumed CPU and memory. The monitoring stack — the thing supposed to be watching the cluster — was actively worsening the memory pressure it was meant to observe.

The node froze. kubectl timed out. SSH hung. I had to reboot the EC2 instance.

When I looked at it clearly: the root cause of the node freezing wasn't memory alone. It was a crashing pod amplifying a memory problem that was already there.

Fix the crash loop first. Before anything else.

📸 `docs/screenshots/197-grafana-33-running.png`
*— The resolution. 3/3 Running after fixing the config and patching the ConfigMap. Same pod. Clean slate.*

But this raises a question I don't have a clean answer to:

At what restart count should Kubernetes just stop trying? Right now it keeps retrying indefinitely with exponential backoff — up to 5 minutes between attempts. Is that the right behaviour? Or should there be a hard limit after which the pod stays down until a human intervenes?

I've seen arguments both ways. What's your take?

#DevOps #Kubernetes #AWS #SRE #LearningInPublic
