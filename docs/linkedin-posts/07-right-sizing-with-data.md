# Post 07 — I Didn't Guess My Cluster Needed More Memory. Prometheus Told Me.

---

Most people resize infrastructure when something breaks.

I resized before it broke — because the data told me to.

📸 `docs/screenshots/162-grafana-cluster-resources.png`
*— Lead thumbnail. The Grafana cluster overview showing 87.4% actual memory usage at idle — before any real traffic, before load testing, before anything stressful. The number speaks for itself. Anyone who's managed servers knows 87% at idle is a problem waiting to happen.*

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus + Grafana + Loki + AlertManager on a 12-microservice ecommerce application. The cluster ran on a t3.medium (2 vCPU, 4GB RAM).

After deploying the full monitoring stack, Grafana showed me:

**Node memory actual usage: 87.4%**
**Monitoring namespace: using 135% of its own requested memory**

87% at idle. Before any real traffic.

I also had a custom AlertManager rule firing at 90% — `HighNodeMemoryUsage`. It was going to fire within days just from normal operation. And it did — twice. Both times the node froze completely. kubectl timed out. SSH hung. Full reboot required.

The monitoring data wasn't just telling me the cluster was busy. It was telling me the cluster had no headroom for anything unexpected. And in production, unexpected is the baseline.

We're upgrading to t3.large — 8GB RAM. Not because something catastrophically failed. Because the metrics showed the trajectory clearly before it became a crisis.

That's what observability is actually for. Not dashboards for their own sake. Not pretty graphs in a presentation. It's the data that lets you make infrastructure decisions before users feel the consequences.

But I want to push back on myself here:

Should I have sized correctly from the start? Is "deploy small, scale when the data says so" actually a good strategy — or is it just a way of creating avoidable incidents while you wait for the metrics to catch up?

"Start small" vs "over-provision and avoid the drama." What's the right default?

#DevOps #Kubernetes #AWS #Observability #CloudEngineering #LearningInPublic
