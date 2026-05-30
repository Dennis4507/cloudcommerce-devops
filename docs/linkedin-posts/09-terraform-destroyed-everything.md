# Post 09 — I Changed One Line of Code. It Deleted Both My Servers.

---

I needed to change the size of my server.

One line of code. Straightforward.

I ran the command. It deleted both servers and rebuilt them from scratch.

Everything I had set up — gone.

📸 `docs/screenshots/87-terraform-forces-replacement-jenkins.png`
*— Lead thumbnail. The tool showing "must be replaced" in red before I ran the command. I saw this warning. I didn't fully understand what it meant.*

I'm building a full ecommerce platform on AWS — 12 services, automated pipelines, monitoring, all managed through code. Every piece of infrastructure written as instructions in files, not clicked together manually.

This approach — called Infrastructure as Code — is how professional teams manage cloud systems. Instead of clicking buttons in a web interface, you write instructions. The tool reads them and builds what you described.

The upside: everything is documented, repeatable, consistent.

The risk: the tool does exactly what the code says. Even if what the code says is "destroy the existing server and build a new one."

I changed the server size in one file. The tool looked at what existed versus what the code said, decided the easiest path was to delete the old server and create a new one — and did exactly that.

New server. Fresh start. Everything I had installed and configured over weeks — wiped.

The tool wasn't wrong. The code said to use a certain type of server. The existing server was a different type. The tool made them match. It did its job perfectly.

I just didn't fully understand the consequences of the instruction I was giving.

📸 `docs/screenshots/91-new-instances-after-destroy.png`
*— New servers running after the rebuild. Clean. Empty. Weeks of work gone.*

The fix was a small addition to the code telling the tool: "if the server type is the only thing different, update it without rebuilding from scratch."

I now read every warning line the tool produces before confirming anything.

But this made me think about something:

When a tool does exactly what it's told but causes significant damage — where does the responsibility sit? With the tool for not warning clearly enough? With the person who ran it? Or with the team that didn't build in a safeguard?

#DevOps #Terraform #AWS #LearningInPublic #CloudEngineering #Tech #IaC
