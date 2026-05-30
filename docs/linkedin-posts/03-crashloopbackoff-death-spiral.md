# Post 03 — I Left a Broken Tool Running. It Quietly Made Everything Worse.

---

One of my monitoring tools was broken and kept crashing.

I knew about it. I left it. I had other things to fix first.

That was a mistake.

📸 `docs/screenshots/193-grafana-crashloopbackoff.png`
*— Lead thumbnail. The dashboard showing one tool crashing repeatedly while everything else runs fine. That one bad row in a sea of green.*

I'm building a full ecommerce platform on AWS — 12 services, automated pipelines, real-time monitoring, all self-funded and built from scratch.

When my monitoring dashboard (Grafana) broke, I assumed it was just sitting there quietly, broken but harmless — like a smoke alarm with a dead battery. Annoying, but not making things worse.

I was wrong.

Every 90 seconds, the broken tool tried to restart itself. Each restart:
- Consumed memory and processing power
- Put more pressure on an already struggling server
- Made the exact problem I was trying to fix worse

The monitoring tool that was supposed to be watching the system was draining the system it was supposed to protect.

Eventually the whole server froze. Nothing responded. I had to do a full restart.

When I looked back at what happened, the sequence was clear:

Broken tool → keeps restarting → uses up resources → server runs out of memory → everything stops → full restart required.

The broken tool was the domino that knocked everything else over.

📸 `docs/screenshots/197-grafana-33-running.png`
*— After the fix. The same tool, now running properly. Three green lights where there were red ones.*

**Fix the broken thing first.** Before anything else. A broken tool is never just sitting there — it's always doing something, and usually that something is making your situation worse.

This makes me wonder — should systems automatically shut down a tool that keeps failing, rather than keep restarting it forever?

I've seen arguments both ways. What's your take?

#DevOps #AWS #SRE #LearningInPublic #Tech #CloudEngineering
