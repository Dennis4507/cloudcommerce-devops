# Post 06 — The Alarm Doesn't Call You. That's Someone Else's Job.

---

I thought the monitoring system sent me the alert email.

It doesn't. That's not its job.

I'm building a full ecommerce platform on AWS — real-time monitoring, automated alerts, 12 services running simultaneously. All self-funded.

When I received my first alert email — telling me something in the system had gone wrong — I assumed the monitoring tool had sent it. It seemed obvious. It spotted the problem, it sent the notification. Simple.

But that's not how it works. And understanding the distinction actually matters.

There are two completely separate tools doing two completely different jobs:

**The monitoring tool (Prometheus)** is like a security guard walking the building. It checks everything constantly — is this door locked? Is that alarm going off? It notices problems. But it doesn't call anyone. That's not its job.

**The notification tool (AlertManager)** is like the control room operator. It receives the report from the security guard, decides who to call, makes sure they're not called 50 times in a row for the same thing, and handles the actual communication.

Two people. Two jobs. Deliberately separate.

📸 `docs/screenshots/220-alertmanager-status-config.png`
*— The notification tool's settings page — showing Gmail connected, routing rules configured, everything wired up correctly.*

The result of this separation: when my dashboard crashed and then recovered, I got two emails automatically.

First: "Something is wrong."
Then, when it fixed itself: "It's fine now, you don't need to do anything."

That second email is important. Without it, you're constantly checking — is it still broken? Did someone fix it? The system handled both without me doing anything.

📸 `docs/screenshots/214-email-resolved-replicasmismatch.png`
*— The actual resolved email landing in Gmail. Problem detected, problem cleared, notification sent both times — automatically.*

Here's what I'm genuinely unsure about:

Some newer tools are combining the monitoring and notification into one system. Is that simpler? Or does keeping them separate — like we have here — actually give you more control and flexibility?

Engineers and non-engineers both welcome — what's your instinct?

#DevOps #AWS #Observability #LearningInPublic #Tech #CloudEngineering
