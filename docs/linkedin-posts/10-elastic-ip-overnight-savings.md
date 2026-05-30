# Post 10 — I Stop My AWS Servers Every Night. This One Decision Made That Possible.

---

Running servers 24/7 in AWS when you're learning and building costs money you don't need to spend.

I stop my EC2 instances every night. Start them in the morning when I need them.

One thing made this practical: Elastic IP.

📸 `docs/screenshots/07-elastic-ips.png`
*— Lead thumbnail. The AWS console showing the Elastic IPs attached to our instances — same IPs every time, regardless of how many times the instances have been stopped and started. Simple screenshot, but it represents a real cost and operational decision.*

I'm building a full DevOps portfolio on AWS — completely self-funded. k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus, Grafana, Loki, AlertManager, 12-microservice ecommerce application. Two EC2 t3.medium instances running the whole platform.

When you stop and start an EC2 instance, AWS assigns it a new public IP address by default. For a learning project where nothing is running in production, this would mean:

- Updating GitHub webhook URLs every morning (Jenkins)
- Updating any hardcoded IP references in configs
- Re-connecting tools that remembered the old IP
- Confusion when something "stops working" and the actual cause is an IP change

An Elastic IP is a static public IP address that stays attached to your instance through stop/start cycles. Same IP every morning. No config changes. No webhook updates. No debugging phantom IP issues.

Cost: free when attached to a running instance. About €3.65/month when the instance is stopped but the IP is reserved.

The alternative — leaving instances running 24/7 — costs roughly €60/month for two t3.mediums. Stopping them overnight (say 16 hours of work time out of 24) cuts that by a third.

Over the course of building this project: meaningful savings for a self-funded portfolio. For a company leaving dev environments running overnight across a team of 10 engineers — multiply that and ask who's actually watching the bill.

This is also why I stopped and started the instance to recover from node memory exhaustion rather than just rebooting — same IP, everything comes back, ArgoCD re-syncs from Git automatically.

One small infrastructure decision. Surprisingly large operational impact.

But here's the question I keep coming back to:

In your organisation, who owns the AWS bill? Is there actually someone checking whether dev environments are running overnight? Or does it just silently accumulate until someone notices the invoice?

I'm curious how mature teams handle this — FinOps policies, automated shutdowns, something else entirely?

#DevOps #AWS #CloudEngineering #FinOps #LearningInPublic #CloudCosts
