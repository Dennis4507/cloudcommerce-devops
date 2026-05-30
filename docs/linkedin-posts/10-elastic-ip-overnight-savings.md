# Post 10 — I Turn My Cloud Servers Off Every Night. One Small Decision Makes That Possible.

---

Running cloud servers 24 hours a day, 7 days a week costs money.

When you're building something yourself, on your own budget, that adds up fast.

I turn mine off every evening. Start them again in the morning.

One decision made that practical.

📸 `docs/screenshots/07-elastic-ips.png`
*— Lead thumbnail. The AWS console showing fixed IP addresses attached to the servers — same addresses every morning, no matter how many times they've been switched off.*

I'm building a full ecommerce platform on AWS — completely self-funded. Every euro matters.

Cloud servers in AWS come with a problem: every time you switch them off and back on, they get a new address on the internet. Like a phone that gets a new phone number every time you restart it.

If your address keeps changing, everything that connects to your server has to be updated every morning. The tools that send updates to your server. The automated systems pointing at it. Every connection that relies on knowing where to find you.

That's not practical for daily use.

The solution is called an **Elastic IP** — a fixed internet address that stays attached to your server no matter how many times you switch it off and on. Same address every morning. Nothing needs to be updated.

Cost: about €3.50 per month. The alternative — leaving servers running overnight — costs around €60 per month for the setup I have.

Switching them off when I'm not working cuts that significantly. Over the course of building this project, that's a real saving.

It also means the "switch off at night" habit is only possible because of this one small decision made at the beginning. Without it, the daily overhead of updating everything that connects to the server would make switching off more trouble than it's worth.

Small infrastructure decisions have long-term operational consequences. This is one I got right early.

But here's what I'm curious about:

In larger companies, does anyone actually track whether development servers are running overnight? Or does the cost just quietly accumulate on the bill until someone notices?

How does your organisation handle it?

#DevOps #AWS #CloudEngineering #FinOps #LearningInPublic #Tech #CloudCosts
