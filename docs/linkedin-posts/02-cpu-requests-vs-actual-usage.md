# Post 02 — CPU Requests vs Actual Usage

---

My Kubernetes node said it was full.

It was also only 12% busy.

Both of those statements were true at the same time.

📸 `docs/screenshots/162-grafana-cluster-resources.png`
*— Lead thumbnail. The Grafana dashboard showing 99.5% CPU reserved vs 12% actual usage side by side. The contradiction is visible before anyone reads a word. Technical people will immediately know the problem. Non-technical people will stare at it and want to understand.*

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus + Grafana monitoring, running a 12-microservice ecommerce application. When I installed the monitoring stack and checked Grafana for the first time, this is what I saw:

**CPU requests committed: 99.5%**
**CPU actual utilisation: 12%**

No new pods could be scheduled. The node was "full." But 88% of its actual CPU was sitting idle.

Here's what was happening:

Every pod has two CPU settings — `requests` and `limits`. Kubernetes uses `requests` for scheduling decisions. When you ask to schedule a new pod, Kubernetes looks at what's been *reserved*, not what's being *used*. Our pods had reserved nearly all available CPU defensively — but at idle, were barely touching it.

The real problem wasn't CPU at all. It was accounting.

A pod with no CPU request gets scheduled as BestEffort — it can land on a "full" node because it made no reservation. A pod with a 50m request cannot — even if the node is barely busy.

The fix was one line. Setting `cpu: null` in the Helm values — explicitly removing the chart default. Not omitting it, not setting it to zero. `null`. Because in Helm, omitting a key leaves the chart default in place. `null` is the only way to delete it.

The node scheduler suddenly had room again.

But here's what I'm still thinking about:

Is aggressive CPU requesting actually the *right* default for most Kubernetes workloads? Or are we all just padding our reservations and wondering why our nodes fill up before they're busy?

How do your teams handle resource requests in production — based on profiling, estimation, or something else entirely?

#DevOps #Kubernetes #AWS #CloudEngineering #LearningInPublic
