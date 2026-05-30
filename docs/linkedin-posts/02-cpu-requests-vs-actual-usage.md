# Post 02 — CPU Requests vs Actual Usage

---

My Kubernetes node said it was full.

It was also only 12% busy.

Both of those statements were true at the same time.

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus + Grafana monitoring, all running a 12-microservice ecommerce application. When I installed the monitoring stack and checked Grafana for the first time, this is what I saw:

**CPU requests committed: 99.5%**
**CPU actual utilisation: 12%**

No new pods could be scheduled. The node was "full." But 88% of its actual CPU was sitting idle.

Here's what was happening:

Every pod has two CPU settings — `requests` and `limits`. Kubernetes uses `requests` for scheduling decisions. When you ask to schedule a new pod, Kubernetes looks at what's been *reserved*, not what's being *used*. Our pods had reserved nearly all available CPU defensively — but at idle, were barely touching it.

The real problem wasn't CPU at all. It was accounting.

A pod with no CPU request gets scheduled as BestEffort — it can land on a "full" node because it made no reservation. A pod with a 50m request cannot — even if the node is barely busy.

We fixed it by setting `cpu: null` on the monitoring pods — explicitly removing the chart defaults. The node scheduler suddenly had room again.

But here's what I'm still thinking about:

Is aggressive CPU requesting actually the *right* default for most Kubernetes workloads? Or are we all just padding our reservations and wondering why our nodes fill up before they're busy?

I'm genuinely curious — how do your teams handle resource requests in production? Do you set them based on profiling, or just estimate and move on?

Drop your approach in the comments. I'm learning and every perspective helps.

#DevOps #Kubernetes #AWS #CloudEngineering #LearningInPublic
