# Loki and Promtail — Deep Dive

## What is Log Aggregation and Why Does It Matter?

Prometheus tells you *what* the system is doing (CPU at 87%, 500 errors/sec). Logs tell you *why* — the exact request, the exact error message, the exact stack trace, with a timestamp accurate to the millisecond.

Without log aggregation on a Kubernetes cluster:
- Logs only exist on the node that ran the pod
- If the pod restarts, the logs are gone
- If you have 12 pods across multiple nodes, checking logs means SSH-ing into each node separately
- There is no way to correlate a log line from service A with a related line from service B that happened in the same request

With Loki + Promtail:
- Every log line from every pod on every node flows into Loki automatically
- Logs are queryable from Grafana alongside metrics — same time window, same interface
- Logs survive pod restarts and node reboots (stored in Loki, not on the pod)
- You can filter by namespace, pod, container, or any Kubernetes label instantly

## What is Loki?

Loki is a log aggregation system built by Grafana Labs. It is often described as "Prometheus for logs" — the design philosophy is deliberately similar:

| | Prometheus | Loki |
|--|--|--|
| Collects | Metrics (numbers) | Logs (text lines) |
| Agent | node-exporter / kube-state-metrics | Promtail |
| Storage | Time-series database | Index + compressed chunks |
| Query language | PromQL | LogQL |
| Grafana integration | Native | Native |

**What makes Loki different from Elasticsearch:**

Traditional log systems (ELK stack: Elasticsearch + Logstash + Kibana) index the full content of every log line. This allows full-text search but is expensive — Elasticsearch clusters are memory-hungry and operationally complex.

Loki takes a different approach: it only indexes **labels** (key-value pairs like `namespace=online-boutique`, `pod=frontend-xxx`). The log content itself is stored compressed but not indexed. This makes Loki much lighter and cheaper to run — at the cost of slower full-text search. For Kubernetes, where labels are first-class citizens, this trade-off is almost always worth it.

## What is Promtail?

Promtail is the log shipping agent. It runs as a **DaemonSet** — one pod on every node in the cluster — and:

1. Watches `/var/log/containers/` on the host node
2. Reads every log line from every container
3. Attaches Kubernetes labels (namespace, pod name, container name) to each line
4. Ships the labelled lines to Loki via HTTP push

Promtail is to Loki what node-exporter is to Prometheus — the agent that gets data from the source into the storage system.

```
Pod → container logs → /var/log/containers/ (on node)
                              ↓
                          Promtail (DaemonSet, one per node)
                              ↓ HTTP push
                            Loki (StatefulSet, stores logs)
                              ↓ queried by
                            Grafana (Explore → LogQL)
```

## Helm Release Name = Service Name (Critical Lesson)

When you install a Helm chart, the **release name** determines the names of all Kubernetes resources — services, deployments, StatefulSets. The release name is set at install time:

```bash
helm install <release-name> <chart>
```

With ArgoCD, the release name is the **ArgoCD Application name**:

```yaml
metadata:
  name: loki   # ← this becomes the Helm release name
```

So when the ArgoCD Application is named `loki` and deploys the `loki-stack` chart:
- The Loki Service is named `loki` (not `loki-stack`)
- The StatefulSet is named `loki`
- The ConfigMap is named `loki-loki-stack` (release-name + chart-name)

This matters for any service that needs to connect to Loki:
- **Promtail push URL:** `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`
- **Grafana data source URL:** `http://loki.monitoring.svc.cluster.local:3100`

Both were initially set with `loki-stack` instead of `loki`, which caused silent failures — Promtail was sending logs into a void and Grafana couldn't connect.

**How to find the correct service name:**
```bash
kubectl get svc -n monitoring | grep loki
```

## CPU Requests vs Actual Usage — Scheduling vs Consumption

The node was at **99.5% CPU requests** but only **12% actual CPU usage**. Kubernetes uses requests for **scheduling decisions** — a pod cannot be placed on a node that lacks the reserved capacity, even if real usage is far below the reservation.

The loki-stack chart defaults to `cpu: 50m` for the Loki pod. That 50m was enough to push scheduling over the limit.

### Why `cpu: null` and Not Just Removing the Key

When Helm installs a chart, it **merges** your values file with the chart's default values. Removing a key from your values file does not remove it — the chart default fills in. The only way to explicitly remove a key is to set it to `null`:

```yaml
# This does NOT work — chart default of 50m fills in
loki:
  resources:
    requests:
      # cpu is simply absent here

# This DOES work — explicitly overrides with null (no request)
loki:
  resources:
    requests:
      cpu: null   # removes the chart default
```

A pod with no CPU request becomes **BestEffort** class — schedulable even when a node is "full" on requests, but first to be throttled if the node is genuinely busy.

## StatefulSet vs DaemonSet Update Behaviour

This was the most subtle bug in the entire Loki deployment.

**DaemonSet (Promtail):** Updates roll out immediately. When the template changes, the DaemonSet controller kills the old pod and creates a new one with the updated spec. The `cpu: null` fix was picked up within seconds.

**StatefulSet (Loki):** Rolling updates only update **Running** pods. A pod in Pending state is never updated. The StatefulSet controller waits for a pod to be Running before applying the updated template.

The sequence that caused the race condition:
1. loki-0 is Pending (can't schedule — CPU requests full)
2. We set `cpu: null` and push to Git
3. ArgoCD syncs and updates the StatefulSet template
4. loki-0 is still Pending — rolling update skips it
5. We delete loki-0 hoping a fresh pod picks up the new template
6. Kubernetes recreates loki-0 **faster than ArgoCD can finish syncing**
7. The new pod gets the old spec (cpu: 50m) because ArgoCD hasn't finished applying yet
8. loki-0 is Pending again with the old spec

**The fix:** Delete the entire StatefulSet, not just the pod. When the StatefulSet is gone, ArgoCD has time to apply the new template on the next sync. Then ArgoCD recreates the StatefulSet from scratch with the correct spec, and the new loki-0 starts with `cpu: null`.

```bash
kubectl delete statefulset loki -n monitoring
# ArgoCD recreates within 3 minutes from Git — correct spec this time
```

## CrashLoopBackOff Is Not Idle — The Death Spiral

A pod in CrashLoopBackOff is not sitting quietly. It:
- Restarts every ~90 seconds (exponential backoff)
- Pulls image layers (CPU + network)
- Initialises the process until it crashes
- Reports the crash to the API server

On a memory-constrained node, a pod crashing 8 times is a pod consuming resources 8 times. Grafana crashing due to the datasource config conflict was actively making the memory pressure worse — the monitoring system was contributing to the very crisis it was supposed to be monitoring.

**This is a real production scenario.** In a large cluster, a CrashLoopBackOff pod that restarts hundreds of times before anyone notices can cause cascading resource exhaustion on the node it runs on. This is why alerting on CrashLoopBackOff count matters — it's not a benign state.

## The Two-Default Datasource Conflict

The loki-stack Helm chart creates a Kubernetes ConfigMap with label `grafana_datasource=1`. This label causes Grafana's sidecar container (grafana-sc-datasources) to pick it up and include it in the provisioned datasource list — even when `grafana.enabled: false` in the loki-stack values. Disabling the embedded Grafana only prevents deploying the Grafana pod itself; it does not prevent the chart from creating the datasource ConfigMap for external Grafana instances to consume.

The ConfigMap set `isDefault: true` for Loki. The kube-prometheus-stack chart also sets `isDefault: true` for Prometheus. Grafana reads both and fails to start:

```
Datasource provisioning error: datasource.yaml config is invalid.
Only one datasource per organization can be marked as default
```

**The fix in two parts:**

1. **Immediate:** Patch the ConfigMap directly to change `isDefault: true` to `isDefault: false`
```bash
kubectl get configmap loki-loki-stack -n monitoring -o yaml > /tmp/loki-cm.yaml
sed -i 's/isDefault: true/isDefault: false/' /tmp/loki-cm.yaml
kubectl apply -f /tmp/loki-cm.yaml
```

2. **Persistent (GitOps):** Add `ignoreDifferences` to the ArgoCD Application so ArgoCD does not revert the patched ConfigMap on the next sync:
```yaml
ignoreDifferences:
  - group: ""
    kind: ConfigMap
    name: loki-loki-stack
    namespace: monitoring
    jsonPointers:
      - /data
```

`ignoreDifferences` tells ArgoCD: "the live state of this resource's data field may differ from what the chart renders — that's intentional, do not flag it as OutOfSync and do not revert it."

## Node Drain vs Stop/Start

When the node became unresponsive (memory exhausted, API server not accepting connections), the resolution was an EC2 stop/start. This is the **single-node equivalent** of the production operation:

**Production (multi-node cluster):**
```bash
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data
# Cordons node (no new pods), evicts all pods to other nodes
# Users feel nothing — pods moved to node-2, node-3
# Fix the root cause
kubectl uncordon node-1  # back in rotation
```

**Single-node (this project):**
- Stop/start on AWS Console
- Everything dies and restarts (brief unavailability)
- ArgoCD resyncs from Git automatically
- All pods come back without manual intervention

**Why the stop/start was safe:** Because everything is defined in Git. No pod configuration, no ArgoCD state, no Kubernetes manifest exists only on the node. The node is ephemeral. The truth is in Git. This is GitOps working as designed.

## LogQL — Querying Logs in Grafana

LogQL is Loki's query language. It follows a similar pattern to PromQL:

```logql
# All logs from online-boutique namespace
{namespace="online-boutique"}

# Only frontend pod logs
{namespace="online-boutique", pod=~"frontend-.*"}

# Filter for error lines
{namespace="online-boutique"} |= "error"

# Parse JSON logs and filter by field
{namespace="online-boutique"} | json | http_resp_status = 500

# Log rate over time (for graphing)
rate({namespace="online-boutique"}[5m])
```

The label selector `{...}` is required in every query — it selects which log streams to read. Everything after `|` is a pipeline that filters or transforms the log lines.

## Interview Talking Points

- "Loki is like Prometheus for logs — same label-based approach, same Grafana integration, but instead of scraping metrics it receives log lines pushed by Promtail agents running as a DaemonSet on every node"
- "We hit a StatefulSet update race condition — the pod was Pending so rolling updates skipped it, and when we deleted the pod it was recreated faster than ArgoCD could push the updated template. The fix was deleting the entire StatefulSet so ArgoCD could recreate it from scratch with the correct spec"
- "The loki-stack chart creates a datasource ConfigMap even with Grafana disabled — it's designed to auto-register Loki with any external Grafana. That ConfigMap set isDefault: true which conflicted with Prometheus. We patched the ConfigMap and used ArgoCD's ignoreDifferences to prevent it being reverted"
- "A pod in CrashLoopBackOff is not idle — every restart cycle consumes CPU and memory. Grafana crashing 8 times was actively worsening the memory pressure it was supposed to be monitoring. In production this is why you alert on CrashLoopBackOff count, not just on service availability"
- "The Helm release name determines every resource name in the chart. Our ArgoCD Application was named 'loki' so the service was named 'loki' — not 'loki-stack' as we initially assumed. Both Promtail and Grafana were configured with the wrong URL, silently failing"
- "When the node was unresponsive, the stop/start was safe because everything is defined in Git. ArgoCD resynced the entire cluster automatically. In production I'd drain the node first to migrate pods with zero downtime — same outcome, no service interruption"
