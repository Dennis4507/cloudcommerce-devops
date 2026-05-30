# Post 05 — I Fixed It. It Broke Again. I Fixed It Again. Same Result.

---

I made a change.

It didn't take effect.

I made the change again. Still nothing.

For 45 minutes I was convinced the system was ignoring me.

📸 `docs/screenshots/178-pod-spec-check-cpu50m.png`
*— Lead thumbnail. The terminal output showing the old setting still in place after we'd already changed it. The system was supposed to update. It hadn't.*

I'm building a full ecommerce platform on AWS — self-funded, learning in public.

I needed to change a setting on one of my services. The service wasn't starting because it was asking for more server resources than were available.

I changed the setting. Saved it. The system updated — I could see the update had been applied.

The service still used the old setting.

I deleted the service and restarted it, thinking a fresh start would pick up the new setting.

The service came back with the old setting again.

Here's what was happening beneath the surface:

The system that manages restarts (called a StatefulSet — think of it as a supervisor that keeps services running) had a rule: only update a service that is currently working. If a service is stuck — not running yet — the supervisor skips it and waits.

My service was stuck waiting for resources. So the supervisor never updated it. And every time I deleted and restarted it, the restart happened so fast that it grabbed the old settings before my update had a chance to be applied.

It was a race. And I kept losing it.

The fix was counterintuitive: instead of restarting the service, I had to shut down the entire supervisor — the thing managing the service — and let the system rebuild it from scratch. That gave the update time to be applied before anything restarted.

📸 `docs/screenshots/176-kubectl-get-pods-monitoring-w.png`
*— Finally. The service coming up correctly after the supervisor was rebuilt from scratch.*

3 minutes of waiting instead of 45 minutes of fighting.

The lesson: sometimes the solution isn't to try harder at the same thing. It's to step back and remove what's in the way.

Has this ever happened to you — working harder at something, only to realise the approach itself was the problem?

#DevOps #AWS #Kubernetes #LearningInPublic #Tech #CloudEngineering
