# Post 07 — I Didn't Guess My Cluster Needed More Memory. Prometheus Told Me.

---

Most people resize infrastructure when something breaks.

I resized before it broke — because the data told me to.

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus + Grafana + Loki + AlertManager observability stack on a 12-microservice ecommerce application. The cluster was running on a t3.medium (2 vCPU, 4GB RAM).

After deploying the full monitoring stack, Grafana showed me this:

**Node memory actual usage: 87.4%**
**Monitoring namespace: using 135% of its own requested memory**

87% at idle. Before any real traffic. Before load testing. Before anything stressful.

I also had a custom AlertManager rule firing at 90% memory — `HighNodeMemoryUsage`. It was going to fire within days just from normal operation.

The node froze twice during setup — not from traffic, just from pods restarting and ArgoCD syncing simultaneously. Both times we had to reboot the EC2 instance.

The monitoring data wasn't just telling me the cluster was busy. It was telling me the cluster had no headroom for anything unexpected. And in production, unexpected is the baseline.

We're upgrading to t3.large — 8GB RAM. Not because something catastrophically failed. Because the metrics showed the trajectory clearly before it became a crisis.

That's what observability is actually for. Not dashboards for their own sake. Not pretty graphs in a presentation. It's the data that lets you make infrastructure decisions before users feel the consequences.

But I want to push back on myself here:

Should I have sized for this from the start? Is "deploy small and scale when the data says so" actually a good strategy — or is it just a way of creating avoidable incidents while you wait for the metrics to catch up?

I've heard both sides. "Start small, scale with evidence" vs "over-provision and avoid the drama." What's the right default?

#DevOps #Kubernetes #AWS #Observability #CloudEngineering #LearningInPublic
