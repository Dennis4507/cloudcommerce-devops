# Post 08 — Why I'm Glad I Started With the Cheaper Server

---

Before I started this project, I did my research.

Every resource said: "For running Kubernetes with multiple services, use a t3.large."

I chose the t3.medium anyway. Half the memory. Half the cost.

Best decision I made.

📸 `docs/screenshots/188-kubectl-tls-timeout.png`
*— Lead thumbnail. kubectl completely failing with TLS handshake timeout — the node frozen, unresponsive. This is the "consequence" image. It shows the struggle was real, not theoretical. People who've seen this error will feel it immediately.*

I'm building a full DevOps portfolio on AWS — completely self-funded. Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus, Grafana, Loki, AlertManager, all running a 12-microservice ecommerce application. Every euro spent is mine. No company card. No learning budget. My own money.

So when research said t3.large, I said: t3.medium first. Let me see what actually breaks.

Here's what broke:

The node froze twice. kubectl stopped responding. SSH hung. I had to reboot the EC2 instance from the AWS console like a person rebooting their home router.

And in the process of figuring out WHY it froze, I learned things I would never have learned on a larger server:

**I learned that a crashing pod isn't idle.** On a t3.large with plenty of headroom, this would have been invisible noise. On my tight node, it froze the entire cluster.

**I learned that Kubernetes scheduling uses reservations, not actual usage.** My node was at 99.5% reserved CPU but only 12% actual usage. New pods couldn't schedule even though the machine wasn't busy.

**I learned that `cpu: null` in Helm is different from omitting the key.** A tiny detail that only matters when you're fighting for every millicore.

**I learned the StatefulSet update race condition.** A Pending pod never gets a rolling update. Delete it and it's recreated before ArgoCD finishes syncing. The fix is deleting the entire StatefulSet. On a t3.large the pod would never have been Pending — so I'd never have found this.

**I learned to read Grafana dashboards with urgency.** Not as pretty graphs. As signals that tell you what's coming before it arrives.

None of this came from a tutorial. It came from being forced to operate under real constraints with real consequences — because it was my money on the line.

📸 `docs/screenshots/216-all-pods-running-alertmanager.png`
*— The other side of the struggle. Everything Running — AlertManager, Prometheus, Grafana, Loki, all 12 microservices. This is what the constraints were building toward.*

We're upgrading to t3.large now. The node earned it. So did I.

But I'd do it the same way again.

Here's what I genuinely don't know:

Is "start small, let it break, learn from the constraints" actually a good strategy? Or is it just romanticising inefficiency — and a better engineer would have sized it correctly from the start and avoided the drama entirely?

Does adversity actually make you learn faster? Or is that just something people say to feel better about struggling?

Would love to hear from engineers who've been in both situations.

#DevOps #Kubernetes #AWS #LearningInPublic #CloudEngineering #CareerDevelopment
