# "Have you tried turning it off and on again?"

*Phase 4 incident — Kubernetes node memory exhaustion, CrashLoopBackOff death spiral, and why GitOps made the oldest IT fix in the book actually work.*

---

Yesterday my Kubernetes node was completely unresponsive. kubectl timing out. SSH hanging. The whole cluster frozen.

So I did the oldest IT fix in the book — I stopped the EC2 instance and started it again.

But here's what made it work, and what I think most people miss:

**The reboot didn't fix anything. GitOps did.**

When the node came back up, I didn't have to:
- Manually restart 19 pods
- Reconfigure Prometheus
- Reinstall ArgoCD
- Redeploy 12 microservices

Everything came back automatically. ArgoCD pulled from Git and reconciled the entire cluster state in minutes. Because in a GitOps system, nothing lives on the node permanently. The node is cattle, not a pet. The truth lives in Git.

A traditional server reboot is an incident. A GitOps cluster reboot is just a brief interruption.

---

**What I also learned about CrashLoopBackOff:**

A pod in CrashLoopBackOff is not idle. It restarts every ~90 seconds — consuming CPU and memory on every attempt. Grafana was crashing due to a datasource config conflict, and that crash loop was actively making the memory pressure worse. The cluster was struggling partly because of the very pod that was supposed to be helping monitor it.

Fixing the config bug was as important as the reboot itself.

---

**The production-correct approach** would have been to drain the node (migrate all pods to healthy nodes, zero downtime for users), fix the root cause, then bring it back into rotation. On a single-node portfolio cluster, stop/start is the equivalent.

Understanding *why* the simple fix works is what separates a junior who reboots and hopes from an engineer who reboots and knows exactly what's about to happen.

Building a full DevOps portfolio on AWS with k3s, Jenkins, ArgoCD, Terraform, Prometheus and Loki. This was Phase 4.

#DevOps #Kubernetes #GitOps #AWS #CloudEngineering #LearningInPublic
