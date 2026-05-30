# Post 05 — The StatefulSet That Wouldn't Update

---

I deleted the pod. It came back wrong.

I deleted it again. Still wrong.

📸 `docs/screenshots/178-pod-spec-check-cpu50m.png`
*— Lead thumbnail. The kubectl output showing the pod spec still has cpu:50m even after we changed the config and ArgoCD synced. The template said one thing. The pod said another. This is the moment of genuine confusion — "I changed it, why isn't it changing?"*

I'm building a full DevOps platform on AWS — k3s Kubernetes, ArgoCD GitOps, Jenkins CI/CD, full observability stack on a 12-microservice ecommerce application. We were deploying Loki for log aggregation. The pod was Pending because the node had no CPU headroom. We fixed the CPU request in the Helm values, pushed to Git, ArgoCD synced.

The StatefulSet template updated correctly. I could see it.

The pod still had the old CPU request. I could see that too.

Here's what was happening:

StatefulSet rolling updates only apply to **Running** pods. The Loki pod was Pending — not Running. The StatefulSet controller looked at it and said: "I'll update you when you're Running." It never ran. So it was never updated.

When I deleted the pod to force a fresh start, Kubernetes recreated it faster than ArgoCD could finish applying the updated template. The new pod grabbed the old spec.

I deleted it again. Same race. Same result.

The fix wasn't deleting the pod. It was deleting the entire StatefulSet. ArgoCD detected the drift, waited for its next sync, and recreated the StatefulSet from scratch with the current Git state. Fresh template. Pod scheduled. Running.

3 minutes of waiting instead of 45 minutes of fighting.

📸 `docs/screenshots/176-kubectl-get-pods-monitoring-w.png`
*— After the StatefulSet delete. Watching pods come back — loki-0 finally moves from Pending to Running with the correct spec.*

What I'm still thinking about:

Is this a design flaw in how StatefulSets handle updates for non-Running pods? Or is it correct behaviour — and the real lesson is that a Pending pod signals a deeper problem that should be fixed before touching the template?

Have you hit this? How did you handle it?

#DevOps #Kubernetes #GitOps #ArgoCD #LearningInPublic
