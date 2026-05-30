# Post 02 — My Server Said It Was Full. It Was Also 88% Empty.

---

My server told me it had no room for anything new.

It was also barely doing any work.

Both were true at the same time.

📸 `docs/screenshots/162-grafana-cluster-resources.png`
*— Lead thumbnail. The dashboard showing 99.5% reserved but only 12% actually being used. The contradiction is visible before anyone reads a word.*

I'm building a full ecommerce platform on AWS — running 12 separate services, monitoring tools, automated deployments, all on cloud servers I'm paying for myself.

When I checked the server dashboard for the first time, I saw this:

**Space reserved: 99.5%**
**Space actually being used: 12%**

No new services could be added. The server was "full." But it was sitting there doing almost nothing.

Here's what was happening — and this is something that catches a lot of people out:

In the world of cloud servers, there's a difference between **reserving** space and **using** space.

Think of it like a restaurant. If every table has a "Reserved" sign on it, the restaurant looks full — even if half those reserved tables are empty all evening. New customers get turned away. But the restaurant is barely busy.

My server worked the same way. Each service had reserved far more space than it actually needed. So the server thought it was full — and refused to add anything new — even though most of that reserved space was sitting unused.

The fix was a single line of code — telling certain services to stop reserving space they weren't using. The server immediately had room again.

But here's the question I'm still thinking about:

Is this a design problem? Should servers be smarter about the difference between reserved and actually used? Or is reserving space defensively actually the right approach — and engineers just need to be more disciplined about how much they reserve?

What do you think?

#DevOps #AWS #CloudEngineering #LearningInPublic #Tech
