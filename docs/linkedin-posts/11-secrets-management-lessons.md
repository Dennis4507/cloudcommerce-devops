# Post 11 — We Tried to Break It. It Taught Us More Than We Planned.

---

We didn't accidentally discover these lessons.

We deliberately tried to create a failure.

It didn't go the way we expected. And that was the most educational part.

📸 `docs/screenshots/228-alertmanager-secret-deleted.png`
*— Lead thumbnail. Deliberately deleting a password from the system — intentional, controlled, part of a plan to demonstrate what happens when it's missing.*

I'm building a full ecommerce platform on AWS — monitoring, alerting, automated deployments, 12 services. All self-funded.

We wanted to show what happens when a server is rebuilt from scratch and a critical password isn't automatically restored. The plan:

1. Upgrade the server to a larger size — switch it off, change the size, switch it back on
2. The password would be gone
3. The alerting system would crash — we'd take screenshots
4. Then fix it properly with a professional solution

**Here's what actually happened:**

**The password didn't disappear.**

When you change a server's size the right way — through the cloud console, not through automated code — the server's hard drive comes back with everything still on it. Like upgrading the engine in a car without touching the boot. Everything in the boot stays exactly where it was.

We were wrong about what would be lost. Stability where we expected failure.

**Then the dashboard broke. For an unrelated reason. Again.**

While the alerting system was running fine, the monitoring dashboard crashed — the same issue we'd fixed before had come back after the restart. We patched it. Again.

**Then we created the failure on purpose.**

We deleted the password manually. Forced the system to restart without it. Watched it fail.

📸 `docs/screenshots/233-alertmanager-failedmount-secret-not-found.png`
*— The system trying and failing to find the missing password 22 times over 30 minutes. This is what a real production failure looks like.*

Then fixed it properly — the password now lives in a secure, permanent storage service from Amazon. A small piece of software we installed automatically fetches it and puts it back in the right place whenever the system starts up. No manual steps. No one needs to remember anything.

---

Three things we learned that weren't in the plan:

**1.** "Switching off and on" means different things depending on how you do it. The consequences can be completely different.

**2.** A fix that worked once doesn't always stay fixed. Some problems need a permanent solution, not a patch.

**3.** The best lessons come not when things fail the way you expected — but when they fail differently, or don't fail at all when you were certain they would.

---

Have you ever set something up to fail on purpose — only to have it teach you something completely different?

#DevOps #AWS #LearningInPublic #CloudEngineering #Tech #CareerDevelopment
