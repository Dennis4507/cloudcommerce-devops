# Post 08 — Why I'm Glad I Started With the Cheaper Server

---

Before I started this project, I did my research.

Every resource said: "For running Kubernetes with multiple services, use a t3.large."

I chose the t3.medium anyway. Half the memory. Half the cost.

Best decision I made.

---

I'm building a full DevOps portfolio on AWS — completely self-funded. Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus, Grafana, Loki, AlertManager, all running a 12-microservice ecommerce application. Every euro spent is mine. No company card. No learning budget. My own money.

So when research said t3.large, I said: t3.medium first. Let me see what actually breaks.

Here's what broke:

The node froze twice. kubectl stopped responding. SSH hung. I had to reboot the EC2 instance from the AWS console like a person rebooting their home router.

And in the process of figuring out WHY it froze, I learned things I would never have learned on a larger server:

**I learned that a crashing pod isn't idle.** It restarts every 90 seconds and burns CPU and memory on every attempt. On a t3.large with plenty of headroom, this would have been invisible noise. On my tight node, it froze the entire cluster.

**I learned that Kubernetes scheduling uses reservations, not actual usage.** My node was at 99.5% reserved CPU but only 12% actual usage. New pods couldn't schedule even though the machine wasn't busy. On a t3.large, there'd have been enough slack that I never would have hit the wall.

**I learned that `cpu: null` in Helm values is different from just omitting the key.** Omitting a key leaves the chart default in place. `null` explicitly removes it. A tiny detail that only matters when you're fighting for every millicore.

**I learned the StatefulSet update race condition.** When a pod is Pending, rolling updates skip it. When you delete it, it gets recreated faster than ArgoCD syncs. The fix is deleting the entire StatefulSet. On a t3.large, the pod would never have been Pending — so I'd never have found this.

**I learned to read Grafana dashboards with urgency.** Not as pretty graphs. As signals. 87% memory at idle isn't a warning. It's a countdown.

None of this came from a tutorial. It came from being forced to operate under real constraints with real consequences — because it was my money on the line.

---

We're upgrading to t3.large now. The node earned it. So did I.

But I'd do it the same way again.

---

Here's what I genuinely don't know though:

Is "start small, let it break, learn from the constraints" actually a good strategy for building technical skills? Or is it just romanticising inefficiency — and a better engineer would have sized it correctly from the start and avoided the drama entirely?

I can see both sides. The constraints taught me things. But they also cost me time.

What do you think — does adversity actually make you learn faster? Or is that just something people say to feel better about struggling?

Would love to hear from engineers who've been in both situations.

#DevOps #Kubernetes #AWS #LearningInPublic #CloudEngineering #CareerDevelopment
