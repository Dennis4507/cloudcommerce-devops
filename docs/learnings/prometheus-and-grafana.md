# Prometheus and Grafana — Deep Dive

## What is Observability?

Observability is the ability to understand what is happening inside a system by looking at its outputs. In Kubernetes, this means answering questions like:

- Which pod is consuming the most memory right now?
- Did CPU spike when the last deployment happened?
- Is any service throwing more errors than usual?
- What happened 3 hours ago that caused the site to slow down?

Without observability tools, these questions require SSH access, manual log reading, and guesswork. With Prometheus and Grafana, they are answered in seconds from a dashboard.

## The Three Pillars of Observability

| Pillar | Tool | What it answers |
|--------|------|-----------------|
| Metrics | Prometheus + Grafana | What is the system doing right now and over time? |
| Logs | Loki + Promtail | What exactly happened and when? |
| Traces | Jaeger | Which service caused the slowdown in a chain of calls? |

This project covers metrics (Phase 4). Logs and traces are the next layers.

## What is Prometheus?

Prometheus is a time-series database and metrics collection engine. It works by **pulling** (scraping) metrics from every component in the cluster at regular intervals (every 15 seconds by default).

Every Kubernetes pod exposes a `/metrics` endpoint — a plain text page of numbers:
```
http_requests_total{method="GET", status="200"} 1234
container_memory_usage_bytes{pod="frontend-xxx"} 67108864
```

Prometheus visits every pod's `/metrics` endpoint, reads those numbers, and stores them with a timestamp. Over time this builds a complete historical record of every metric across every pod.

**Pull vs Push:** Prometheus pulls metrics from pods rather than pods pushing to Prometheus. This means Prometheus controls the scrape interval and a misconfigured pod cannot flood Prometheus with data.

## What is Grafana?

Grafana is a visualisation layer. It does not collect metrics — it queries Prometheus and draws the results as charts and dashboards.

```
Prometheus (stores data) ←scrapes── pods
         ↓ queried by
      Grafana (shows dashboards)
```

Grafana speaks **PromQL** (Prometheus Query Language) to ask Prometheus questions:

```promql
# CPU usage for all online-boutique pods
sum(rate(container_cpu_usage_seconds_total{namespace="online-boutique"}[5m]))

# Memory usage per pod
container_memory_working_set_bytes{namespace="online-boutique"}
```

The kube-prometheus-stack chart pre-loads 20+ dashboards written in PromQL that answer the most common Kubernetes questions without writing any queries manually.

## kube-prometheus-stack — One Chart, Five Components

Installing Prometheus and Grafana separately requires coordinating versions, service discovery configuration, and dashboard imports. The **kube-prometheus-stack** Helm chart packages everything together:

| Component | Role |
|-----------|------|
| Prometheus | Scrapes and stores all metrics |
| Grafana | Dashboards and visualisation |
| Prometheus Operator | Manages Prometheus config via Kubernetes CRDs (ServiceMonitor, PodMonitor) |
| kube-state-metrics | Exposes Kubernetes object state as metrics (pod phases, deployment replica counts) |
| node-exporter | Exposes host-level OS metrics (EC2 CPU, disk I/O, network throughput) |

**Prometheus Operator** is the key piece that makes Kubernetes-native monitoring work. Instead of writing Prometheus scrape configs manually, you create `ServiceMonitor` custom resources in Kubernetes — the Operator watches for them and automatically updates Prometheus configuration. Adding a new service to monitoring is a Kubernetes manifest, not a config file edit.

## Resource Requests vs Actual Usage — What the Metrics Revealed

After deploying the stack, Grafana showed a critical distinction:

**CPU:** 12% actual utilisation, 99.5% requests commitment

This means pods have reserved almost all available CPU via their `resources.requests.cpu` settings, but are actually using only 12% of the node's CPU. The reservations are Kubernetes' scheduling guardrails — they prevent new pods from being scheduled even if actual usage is low.

**Memory:** 87.4% actual utilisation, 57.1% requests commitment

Memory tells the opposite story — actual usage is high (87.4%) but requests are only 57.1% committed. This means pods are using MORE memory than they reserved, which is possible because Kubernetes only enforces limits (not requests) for memory eviction.

**The monitoring stack underestimating its own memory:**

```
monitoring namespace:
  Requested: 492 MiB
  Actual:    664 MiB  (135% of requested)
```

Prometheus in particular uses more memory than its request because it holds scraped metrics in memory before flushing to disk. The values file needs to be updated:

```yaml
prometheus:
  prometheusSpec:
    resources:
      requests:
        memory: 512Mi   # was 300Mi — increase to match actual usage
      limits:
        memory: 800Mi   # was 600Mi
```

This is a real production concern: a pod using more memory than its request can be evicted by Kubernetes when the node is under pressure, even if it hasn't hit its limit.

## NodePort vs Ingress for Grafana Access

Grafana is exposed via NodePort 30030:

```yaml
grafana:
  service:
    type: NodePort
    nodePort: 30030
```

This means `http://63.184.235.88:30030` reaches Grafana directly. NodePort works but has limitations:
- Port must be in the 30000-32767 range (ugly URLs)
- Bypasses Traefik's routing logic
- Not suitable if multiple services need to share port 80

The production approach: use a Traefik Ingress that routes `http://63.184.235.88/grafana` to the Grafana service. This keeps everything on port 80 and uses path-based routing. For this portfolio project, NodePort is acceptable.

## Security Group vs Kubernetes Service — Two Separate Layers

Exposing Grafana requires both:

1. **Kubernetes Service (NodePort)** — routes traffic from the EC2 host port (30030) to the Grafana pod port (3000). Configured in the Helm values.

2. **AWS Security Group inbound rule** — allows traffic to reach port 30030 on the EC2 instance from the internet. Configured in Terraform.

Both must be open. If the Kubernetes Service is configured but the security group is closed, the connection times out at the AWS boundary before reaching Kubernetes. This is the "two separate firewalls" model — AWS and Kubernetes each have their own.

## Why Monitoring Lives Inside k3s (Portfolio) vs Outside (Production)

**Portfolio (current):** Prometheus and Grafana run as pods inside the same cluster they monitor. If the cluster dies, monitoring dies too.

**Production:** Monitoring runs on a separate server or cluster. When the app cluster crashes, monitoring is still accessible — you can see exactly what metrics looked like in the minutes before the crash.

The configuration is identical. The difference is operational maturity and cost. Knowing this distinction and being able to articulate it is what matters in an interview.

## Interview Talking Points

- "We deployed the kube-prometheus-stack Helm chart via ArgoCD — one chart installs Prometheus, Grafana, the Prometheus Operator, kube-state-metrics, and node-exporter. The Operator is key: it manages Prometheus scrape configuration through Kubernetes custom resources rather than config files"
- "Grafana showed us 12% actual CPU utilisation against 99.5% reserved — this is the difference between Kubernetes scheduling (reservations prevent new pods scheduling) and actual consumption (pods idle at 12%)"
- "Memory was at 87.4% actual usage. The monitoring stack itself was exceeding its requested memory at 135% — this is a real production concern because Kubernetes can evict pods that exceed their requests when the node is under memory pressure"
- "Exposing Grafana required two separate changes: a NodePort Kubernetes Service and an AWS security group inbound rule. The security group is the AWS boundary — without it, traffic never reaches Kubernetes regardless of how the service is configured"
- "In production, monitoring runs on a separate cluster so it survives app cluster failures. For this project, co-location on the same node was the cost-appropriate decision — the concepts and configuration are identical"
- "Prometheus works by pulling metrics from pod /metrics endpoints every 15 seconds — this pull model means Prometheus controls the scrape rate and a misconfigured service cannot flood the metrics system"
