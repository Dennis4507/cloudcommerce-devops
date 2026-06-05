# HPA and Load Testing — Deep Dive

What was learned building and running Horizontal Pod Autoscaling with k6 load testing on this cluster. Not just the theory — the actual behaviour observed, the mistakes made, and the non-obvious things that matter in practice.

---

## HPA — How It Actually Works

### The Scaling Formula

HPA uses one formula to decide how many replicas are needed:

```
desiredReplicas = ceil(currentReplicas × (currentMetricValue / desiredMetricValue))
```

In plain English: "how many pods do I need so the average CPU per pod is at or below the target?"

**Real example from this project:**
```
currentReplicas:      1
currentCPU:           110% (of request)
targetCPU:            50%

desiredReplicas = ceil(1 × 110/50)
               = ceil(2.2)
               = 3
```

HPA went straight from 1 to 3 — not 1 to 2. Because even 2 pods would still average 55% each (still above 50%). Only 3 pods brings the average below the threshold.

**Key insight:** HPA skips intermediate steps. It calculates the final number needed and jumps there. You won't always see 1→2→3 — you might see 1→3 directly if load is high enough.

---

### CPU % Means Percentage of REQUEST — Not Node CPU

This is the most important thing to understand about HPA. The percentage shown in `kubectl get hpa` is **not** percentage of the node's CPU. It is percentage of the pod's **CPU request**.

```
Pod has: requests.cpu = 50m
Actual usage:        55m

HPA sees: 55m / 50m = 110%
Node sees: 55m / 2000m (total node) = 2.75%
```

This is why `kubectl get hpa` can show `110%/50%` while `kubectl top node` shows CPU at 15%. Two completely different measurements.

**Why this matters:** If your CPU requests are set too low relative to actual usage, HPA triggers constantly. If they're set too high, HPA never triggers even under real load. Requests should be set to typical/average usage (not peak, not idle). Use Prometheus metrics to find the real number.

---

### HPA Uses metrics-server — Not Prometheus

Common misconception: HPA reads from Prometheus. It does not.

```
HPA controller
    ↓ reads from
metrics-server API (aggregated CPU/memory from kubelet)
    ↓ NOT
Prometheus (that's for dashboards and alerting)
```

metrics-server polls the kubelet on each node every 15 seconds. kubelet reports the actual container CPU and memory usage. metrics-server aggregates this and exposes it via the Kubernetes Metrics API (`kubectl top` uses this same API).

HPA checks this API on its own schedule (default: every 15 seconds). This is why there's a slight delay between CPU spiking and HPA creating new pods — it takes up to 30 seconds for the metrics to propagate and HPA to act.

**In this project:** metrics-server was already installed by k3s (it's a default k3s component). No extra setup was needed for HPA to work.

---

### The Behavior Section — Why It Matters

Without a `behavior` section, HPA uses defaults that can cause thrashing:

```yaml
# What we configured:
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0     # scale up immediately
    policies:
    - type: Pods
      value: 1
      periodSeconds: 30               # add 1 pod per 30 seconds max

  scaleDown:
    stabilizationWindowSeconds: 60    # wait 60s before scaling down
    policies:
    - type: Pods
      value: 1
      periodSeconds: 60               # remove 1 pod per minute max
```

**Why scale-up is immediate (0s) but scale-down waits (60s):**

Scale-up being slow = users get errors while waiting for new pods.
Scale-down being fast = pods terminate the moment traffic dips, then a new request spikes → scale-up again → termination → repeat. This is thrashing.

The asymmetric timing is deliberate:
- **Scale up**: respond to load as fast as possible
- **Scale down**: wait to make sure the load drop is real, not a momentary dip

In this test run, after k6 finished:
```
CPU drops below 50%
    ↓
HPA waits 60 seconds (making sure it's not just a momentary gap)
    ↓
Removes 1 pod per minute (not all at once)
    ↓
Traffic distribution changes gradually, no sudden loss of capacity
```

---

### Single-Node HPA Constraint

On a single-node cluster, HPA scales pods but all new pods land on the same node. This means:

- The **mechanism** is demonstrated correctly (HPA fires, pods created)
- The **benefit** is limited (all pods compete for the same CPU on one machine)
- Real performance improvement requires multiple nodes with Cluster Autoscaler

In production (EKS, multi-node):
```
HPA: "need 3 replicas"
Scheduler: pod 1 → node in eu-central-1a
           pod 2 → node in eu-central-1b
           pod 3 → node in eu-central-1c
Each pod has dedicated CPU on its own machine — true horizontal scaling
```

This is the documented limitation of running HPA on single-node k3s. The concept, configuration, and GitOps delivery are production-identical. Only the node topology differs.

---

### What checkoutservice Taught Us

checkoutservice had an HPA configured (max 2, target 50%) but never scaled — it stayed at 4% CPU throughout the entire test, even at 40 virtual users.

**Why:** Each checkout involves multiple service calls (cart → currency → payment → shipping → email). The checkoutservice handles the orchestration but delegates the actual work. It's CPU-light by design. Under 40 VUs, it had plenty of headroom.

**The lesson:** Set HPAs on services that are actually bottlenecks under load, not every service. Use Prometheus data to identify which services actually spike. Configuring HPA everywhere adds noise (the HPA controller still runs the loop) without benefit.

---

## k6 — How It Works

### The Mental Model

```
k6 runs a JavaScript function (your test script)
    ↓
Multiple virtual users (VUs) each run that function simultaneously
    ↓
Each VU runs the function in a loop for the test duration
    ↓
k6 measures every HTTP request made by every VU
    ↓
Metrics are written to Prometheus or printed at the end
```

A VU is not a real browser — it's a lightweight goroutine that makes HTTP requests. 40 VUs making requests every 4 seconds = ~10 requests/second steady state.

---

### Stages — Shaping the Load Profile

```javascript
stages: [
  { duration: '30s', target: 5  },   // ramp up — 0 → 5 VUs over 30 seconds
  { duration: '60s', target: 20 },   // ramp up — 5 → 20 VUs over 60 seconds
  { duration: '90s', target: 40 },   // ramp up — 20 → 40 VUs over 90 seconds
  { duration: '30s', target: 20 },   // ramp down — 40 → 20
  { duration: '60s', target: 0  },   // ramp down — 20 → 0
]
```

**Why ramp up instead of starting at 40?**

Starting at 40 VUs instantly is a spike test — it simulates a sudden surge. Ramping up is a stress test — it simulates organic load growth. For watching HPA scale, ramping gives you a visible progression: see when the threshold is crossed and the first pod appears.

---

### Checks vs Thresholds

Two separate concepts that look similar but do different things:

**Checks** — assertions on individual requests:
```javascript
check(res, {
  'homepage status 200': (r) => r.status === 200,
  'homepage has products': (r) => r.body.includes('Hot Products'),
});
```
Checks pass or fail per request. A failed check does NOT stop the test. It just increments the failure counter.

**Thresholds** — aggregate pass/fail criteria for the whole test:
```javascript
thresholds: {
  http_req_failed: ['rate<0.05'],    // fail the test if >5% of requests fail
  http_req_duration: ['p(95)<3000'], // fail the test if p95 latency > 3s
}
```
Thresholds determine if the test PASSES or FAILS overall. k6 exits with a non-zero code if a threshold is breached — making it suitable for a CI/CD pipeline (`--exit-on-error`).

**In this run:** We passed both thresholds. 4.8% failure rate (just under 5%) and response times within limits.

---

### k6 → Prometheus → Grafana Pipeline

```
k6 (WSL) → HTTP POST → Prometheus port 30090 → stored as time series
                                                     ↓
                                              Grafana queries Prometheus
                                                     ↓
                                         Dashboard 18030 shows k6 metrics
```

**What k6 sends to Prometheus:**
Every k6 built-in metric gets a `k6_` prefix:
- `k6_http_reqs_total` — total request count
- `k6_http_req_failed_rate` — failure rate
- `k6_http_req_duration` — response time (as a histogram)
- `k6_vus` — current virtual user count
- `k6_iterations_total` — completed test iterations

**Enabling remote write in Prometheus:**
```yaml
# kube-prometheus-stack-values.yaml
prometheus:
  service:
    type: NodePort
    nodePort: 30090          # expose Prometheus outside the cluster
  prometheusSpec:
    enableRemoteWriteReceiver: true   # accept POST to /api/v1/write
```

**Running k6 with remote write:**
```bash
K6_PROMETHEUS_RW_SERVER_URL=http://63.184.235.88:30090/api/v1/write \
k6 run --out experimental-prometheus-rw scripts/k6-load-test.js
```

---

### Native Histograms vs Standard — What Failed and Why

When `K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true` was added, Prometheus returned 500 errors:

```
ERRO Failed to send the time series data to the endpoint
error="got status code: 500 instead expected a 2xx"
```

**Root cause:** Native histograms are a newer Prometheus feature (introduced in 2.40) that requires an explicit feature flag:

```yaml
# What would be needed to fix this:
prometheusSpec:
  enableFeatures:
    - native-histograms
```

Without this flag, Prometheus rejects native histogram encoded data with a 500.

**Standard metrics worked fine** — the first test run (without the native histogram flag) produced all the data visible in Grafana dashboard 18030. The "No data" panels (latency timings) require native histograms but everything else worked.

**Lesson:** Don't add flags you haven't verified are supported by the receiving system. Check the Prometheus version and enabled features before enabling native histograms.

---

### The Line Continuation Problem in WSL

When a long command spans multiple lines using `\`, WSL shows `>` on the next line — this is a prompt indicating "still waiting for input." The problem occurs when you accidentally type `>` yourself:

```bash
# Correct — \ at the end continues the command
K6_PROMETHEUS_RW_SERVER_URL=http://... \
k6 run --out ...

# What went wrong — extra > typed after \
K6_PROMETHEUS_RW_SERVER_URL=http://... \
> > k6 run ...   ← the > > is redirection, not continuation
```

`> >` in bash means "redirect stdout to file named '>'" — which creates a junk file in the directory.

**Fix:** Put everything on one line when using multi-part environment variable commands:

```bash
K6_PROMETHEUS_RW_SERVER_URL=http://63.184.235.88:30090/api/v1/write k6 run --out experimental-prometheus-rw scripts/k6-load-test.js
```

One line, no backslash, no continuation issues.

---

### The 9.5% Cart Failure — Why It Happened

At peak load (40 VUs), 9.5% of add-to-cart requests returned 500. The load generator pod was also hitting the site simultaneously. Two things contributing:

1. **cartservice saturation** — at 63% CPU with 40 VUs + loadgenerator, some requests timed out internally
2. **session handling under load** — the frontend uses session cookies for cart state; under concurrent load, some session lookups failed

The cart view (reading the cart) had 100% success — only writes (adding items) failed. This is a classic pattern: reads survive load better than writes because reads are stateless.

**This 9.5% is actually useful data.** It shows the service degrades gracefully under load — returning errors instead of crashing. The pods kept running. The cluster stayed healthy. That is the correct production behaviour.

---

## Interview Talking Points

**"How does HPA work?"**
> "HPA uses a formula: desired replicas = ceil(current replicas × current CPU% / target CPU%). The percentage is against the pod's CPU request, not the node total. It reads from metrics-server every 15 seconds — not Prometheus. On our cluster, frontend hit 110% of its 50m request at 40 concurrent users, which calculated to 3 replicas needed. HPA went straight from 1 to 3."

**"What's the difference between requests and limits in the context of HPA?"**
> "Requests are what HPA uses as the denominator for its percentage calculation. If a pod requests 50m CPU and actually uses 55m, HPA sees 110% — even though the node might only be at 3% overall CPU. Limits are the ceiling the kernel enforces — if a pod exceeds its CPU limit, it gets throttled. HPA never looks at limits, only requests."

**"Why did you set scale-down stabilisation to 60 seconds?"**
> "To prevent thrashing. Without a stabilisation window, a momentary drop in load causes HPA to remove a pod, traffic spikes again, HPA adds it back, traffic drops — repeat. 60 seconds means the load has to stay below the threshold for a full minute before HPA acts. Scale-up is kept at 0 seconds because users are waiting — you want new capacity as fast as possible."

**"How does k6 integrate with Grafana?"**
> "k6 supports Prometheus remote write — it pushes metrics directly to Prometheus's `/api/v1/write` endpoint every few seconds during the test. Prometheus stores them as time series. Grafana queries Prometheus like any other metric. The result is a combined view: k6's virtual user count and request rate on the same dashboard as Kubernetes CPU metrics and pod replica counts. You can see the load going in and the cluster response — at the same time, on the same screen."

**"What was the failure rate and what caused it?"**
> "4.8% overall — just under our 5% threshold. The failures were concentrated in add-to-cart writes at peak load (9.5% failure rate), while reads — viewing the cart, loading the homepage — had 100% success throughout. Under extreme load, write operations fail before reads because they require state management. The service degraded gracefully: returning errors rather than crashing. That is correct production behaviour."
