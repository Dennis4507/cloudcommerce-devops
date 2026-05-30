# Post 07 — The Dashboard Told Me I Needed a Bigger Server. Before It Became a Problem.

---

I didn't guess my server needed upgrading.

The data told me. Weeks before it became a crisis.

📸 `docs/screenshots/162-grafana-cluster-resources.png`
*— Lead thumbnail. The dashboard showing 87% memory used — at rest, before any real traffic. The number that started the conversation.*

I'm building a full ecommerce platform on AWS — 12 services, monitoring, automated pipelines, all self-funded.

After setting up the monitoring dashboards, the first thing they showed me was this:

**87% of memory used — at idle.**

Not under load. Not during a busy period. Just... sitting there, doing nothing much, already at 87%.

In any system — servers, warehouses, office buildings — being at 87% capacity at your quietest moment is a warning. It means one busy spell, one unexpected spike, and you're over the limit.

And that's exactly what happened. Twice.

The server froze. Everything stopped responding. I had to do a full restart both times.

The difference between our situation and most: I could see it coming. The dashboard was showing me the trend. I knew the server was running out of headroom — I just hadn't acted on it fast enough.

We upgraded to a larger server. Double the memory. The data made the decision, not a guess.

That's what monitoring tools are actually for. Not pretty graphs on a screen. Not something to set up and forget. They're the early warning system that lets you make decisions before your users feel the consequences.

A mechanic doesn't wait for the engine to fail before checking the oil. Same principle.

But here's the question that's been on my mind:

Should I have sized the server correctly from the start? Is "start small, watch the data, then upgrade" actually smart — or is it just creating problems on purpose and calling it a learning experience?

I genuinely don't know the right answer. What's your view?

#DevOps #AWS #CloudEngineering #LearningInPublic #Tech #Observability
