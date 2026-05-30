# Post 06 — Prometheus Doesn't Send Alerts

---

I thought Prometheus sent the alert email.

It doesn't. It never did.

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, full observability stack on a 12-microservice ecommerce application. When I set up alerting and the first email arrived, I assumed Prometheus had sent it. It seemed obvious — Prometheus detected the problem, Prometheus sent the notification.

But that's not how it works at all.

Prometheus and AlertManager are two completely separate systems with a deliberate split of responsibility:

**Prometheus** evaluates rules. Every 15 seconds it runs PromQL queries against its metrics. If a condition is true for long enough — say, a pod has restarted 5 times in 15 minutes — it marks the alert as Firing and sends it to AlertManager via HTTP. That's where Prometheus's job ends.

**AlertManager** decides what to do with the alert. It applies routing rules, deduplicates, groups related alerts together, respects silences, enforces repeat intervals so you don't get spammed, and then sends the actual notification — email, Slack, PagerDuty, whatever you configured.

Prometheus knows nothing about email. AlertManager knows nothing about metrics.

The result: we received a `[RESOLVED]` email automatically when Grafana recovered from CrashLoopBackOff — without writing a single line of recovery logic. AlertManager handled it because `send_resolved: true` was in the receiver config.

But here's what I'm wondering:

This two-system architecture adds complexity. You have to configure and operate both. Some newer tools (Grafana OnCall, for example) are collapsing this into a single system. Is the separation still worth it? Or is it historical baggage from when these tools were built?

Experienced engineers — is there a real operational reason to keep them separate, or would you prefer one unified system?

#DevOps #Kubernetes #Prometheus #Observability #SRE #LearningInPublic
