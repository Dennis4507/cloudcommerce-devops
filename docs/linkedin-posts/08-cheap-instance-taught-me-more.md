# Post 08 — Why I'm Glad I Started With the Cheaper Server

---

Before I started, I did the research.

Everything pointed to the same answer: get the bigger server.

I got the cheaper one instead.

Best decision I made.

📸 `docs/screenshots/188-kubectl-tls-timeout.png`
*— Lead thumbnail. The server completely unresponsive. This is what "learning the hard way" looks like on a screen.*

I'm building a full ecommerce platform on AWS — 12 services, automated deployments, real-time monitoring, alerting. Completely self-funded. Every euro is mine.

When everything pointed to the bigger server, I said: let me start small. Let me see what actually breaks.

Here's what broke:

The server froze. Twice. Completely. Nothing responded. I had to restart it from the cloud console like turning off a frozen laptop.

And in figuring out WHY it froze, I learned things I never would have learned on a bigger server with comfortable headroom:

**I learned that a crashing tool isn't doing nothing.** It's restarting constantly, draining resources, quietly making everything worse. On a bigger server, this would have been invisible. On mine, it froze the whole thing.

**I learned the difference between reserved space and used space.** The server thought it was full at 99%. It was actually 88% empty. A bigger server would have hidden this confusion completely.

**I learned how systems behave under pressure.** Update conflicts. Timing issues. One service blocking another. These things only surface when resources are tight. A comfortable server masks them.

**I learned to read the warning signs early.** Not after things broke, but while they were still manageable. That skill transfers everywhere.

None of this came from a tutorial. It came from real constraints with real consequences — because it was my own money.

📸 `docs/screenshots/216-all-pods-running-alertmanager.png`
*— The other side. Everything running smoothly after working through every problem. This is what the tight constraints were building toward.*

We upgraded to the bigger server eventually. The data said it was time. But I'd do it the same way again.

Here's what I'm still thinking about:

Is "start small and let reality teach you" actually a good strategy? Or is it just making avoidable mistakes and calling it a learning experience?

I've heard both sides from people I respect. What's yours?

#DevOps #AWS #LearningInPublic #CloudEngineering #Tech #CareerDevelopment
