# Post 04 — I Did Everything Right. The Website Still Wouldn't Load.

---

I set everything up correctly on my end.

The website still wouldn't open.

📸 `docs/screenshots/158-grafana-connection-timeout.png`
*— Lead thumbnail. The browser showing "This site can't be reached." Familiar to everyone — technical or not.*

I'm building a full ecommerce platform on AWS — 12 services, monitoring dashboards, automated deployments. All running on cloud infrastructure.

I deployed my monitoring dashboard. Checked that it was running. Checked the settings. Everything looked right.

Opened the browser. Connection timed out.

I spent time checking my own setup. Everything was correct. The service was running. The settings were fine.

The problem was somewhere completely different — somewhere I hadn't thought to look.

Here's the thing about cloud infrastructure that nobody explains clearly at the start:

**There are two separate security layers between the internet and your application. Both have to be open.**

Think of it like an office building:
- The **AWS security group** is the building's front door — controlled by Amazon. It decides what traffic is even allowed to reach the building.
- The **application service** is your office door — controlled by you. It decides who inside the building can get to your desk.

I had my office door open. But the building's front door was still locked.

It didn't matter how perfectly I'd set up my side — traffic never even got to the building.

📸 `docs/screenshots/159-security-group-30030-added.png`
*— The fix. Opening the front door. Two minutes in the AWS settings. Dashboard loaded immediately.*

Two minutes to add one rule in the AWS console. Dashboard loaded immediately.

The code for that rule was already written — I just hadn't activated it yet. The instructions existed. The action hadn't been taken.

This raises a question I'm genuinely curious about:

In your company, when a developer makes a manual change to fix something in production — is that acceptable? Or is every change supposed to go through a formal process, no exceptions?

#DevOps #AWS #CloudEngineering #LearningInPublic #Tech
