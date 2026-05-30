# AlertManager — Deep Dive

## Prometheus vs AlertManager — Two Separate Concerns

A common misconception is that Prometheus sends alerts. It does not. Prometheus **evaluates** alert conditions and **hands off** to AlertManager. They are deliberately separate systems:

| | Prometheus | AlertManager |
|--|--|--|
| Knows about | Metrics, time series, PromQL | Receivers, routes, silences |
| Job | Evaluate rules, detect problems | Route, deduplicate, throttle, notify |
| Sends to | AlertManager | Email, Slack, PagerDuty, etc. |

This separation means:
- Multiple Prometheus instances can send to one AlertManager
- AlertManager can receive alerts from non-Prometheus sources
- You can change notification channels without touching Prometheus rules
- Silencing an alert in AlertManager doesn't affect Prometheus evaluation

## How Alerting Works End-to-End

```
1. Prometheus evaluates a PromQL rule every 15s (evaluation_interval)
   e.g. rate(kube_pod_container_status_restarts_total[15m]) * 900 > 5

2. If condition is true for longer than `for:` duration (e.g. 5m)
   → alert state changes from Pending → Firing

3. Prometheus sends the firing alert to AlertManager via HTTP

4. AlertManager applies routing:
   - Which receiver? (gmail, slack, null)
   - Group with similar alerts? (group_by)
   - Wait before sending? (group_wait)
   - Already sent recently? (repeat_interval)

5. AlertManager sends notification (email, webhook, etc.)

6. When condition clears → alert moves to Resolved
   → AlertManager sends [RESOLVED] if send_resolved: true
```

## PrometheusRule — How Alert Rules Are Defined

In Kubernetes, alert rules are defined as `PrometheusRule` custom resources. The Prometheus Operator watches for these and automatically loads them into Prometheus — no config file editing needed.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-alerts
  namespace: monitoring
spec:
  groups:
    - name: pod.rules
      rules:
        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[15m]) * 900 > 5
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.pod }} is crash looping"
            description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} has restarted more than 5 times in 15 minutes."
```

In our project, rules are defined via `additionalPrometheusRulesMap` in the kube-prometheus-stack Helm values — the chart generates the PrometheusRule CRD automatically.

Key fields:
- **`expr`** — the PromQL query. If it returns any results, the alert condition is met
- **`for`** — how long the condition must be true before firing (prevents flapping)
- **`labels`** — added to the alert, used for routing in AlertManager (e.g. `severity: critical`)
- **`annotations`** — human-readable context sent with the notification

## AlertManager Configuration Structure

```yaml
config:
  global:
    # Default SMTP settings for all email receivers
    smtp_smarthost: 'smtp.gmail.com:587'
    smtp_from: 'alerts@example.com'
    smtp_auth_username: 'alerts@example.com'
    smtp_auth_password_file: /etc/alertmanager/secrets/my-secret/password
    smtp_require_tls: true

  route:
    # Default receiver for all alerts
    receiver: 'gmail'
    group_by: ['alertname', 'namespace']
    group_wait: 30s       # collect alerts for 30s before first notification
    group_interval: 5m    # wait 5m before notifying about new alerts in same group
    repeat_interval: 4h   # re-notify if still firing after 4h
    routes:
      # Child routes — override default for specific alerts
      - receiver: 'null'
        matchers:
          - alertname =~ "Watchdog|InfoInhibitor"

  receivers:
    - name: 'null'         # discard silently
    - name: 'gmail'
      email_configs:
        - to: 'oncall@example.com'
          send_resolved: true

  inhibit_rules:
    # Suppress warning/info if critical fires for same namespace+alertname
    - source_matchers:
        - severity="critical"
      target_matchers:
        - severity=~"warning|info"
      equal: ['namespace', 'alertname']
```

## The `null` Receiver — Standard Production Pattern

AlertManager requires every route to reference a receiver that exists. The `Watchdog` alert fires constantly as a heartbeat — it proves the entire alerting pipeline is functioning. You don't want to receive this email every 4 hours.

The `null` receiver is a named receiver with no configuration — it accepts alerts and discards them silently:

```yaml
receivers:
  - name: 'null'   # no config = no notifications sent
```

This is a universal AlertManager pattern. In production you might also route:
- Low-priority info alerts → null (don't page on-call for info)
- Internal test alerts → null
- Alerts under active maintenance → null (via silences)

## SMTP Secret — Never in Git

AlertManager needs an SMTP password. This must never be in a Git-tracked file. The correct approach:

**1. Create a Kubernetes Secret directly on the cluster:**
```bash
kubectl create secret generic alertmanager-smtp-secret \
  --from-literal=gmail-password='your-app-password' \
  -n monitoring
```

**2. Mount the secret into AlertManager via Helm values:**
```yaml
alertmanager:
  alertmanagerSpec:
    secrets:
      - alertmanager-smtp-secret   # mounts at /etc/alertmanager/secrets/
```

**3. Reference via file path in the config (not plaintext):**
```yaml
global:
  smtp_auth_password_file: /etc/alertmanager/secrets/alertmanager-smtp-secret/gmail-password
```

The secret is readable by AlertManager at runtime but never appears in any YAML file committed to Git. If the cluster is destroyed and rebuilt, recreate the secret manually before ArgoCD syncs.

## Gmail App Password vs Regular Password

Google blocks SMTP login with your regular Google password when 2-Step Verification is enabled. An **App Password** is a 16-character token that grants SMTP-only access:

1. Go to myaccount.google.com/apppasswords
2. Requires 2-Step Verification to be ON
3. Generate for "Mail" + "Other device"
4. Copy the 16 chars — shown once only
5. Use this (without spaces) as the SMTP password

App Passwords can be revoked individually — if AlertManager is compromised, you revoke just that token without changing your Google password.

## Inhibit Rules — Preventing Alert Storms

When a node goes down, dozens of alerts fire simultaneously — all pods on that node are unreachable, all services are down. Without inhibit rules, your on-call engineer gets 50 emails in 2 minutes.

Inhibit rules suppress lower-priority alerts when a higher-priority alert is already firing for the same target:

```yaml
inhibit_rules:
  # If critical fires for namespace X + alertname Y
  # → suppress warning and info for same namespace X + alertname Y
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity=~"warning|info"
    equal: ['namespace', 'alertname']
```

This means: if `KubePodCrashLooping` (critical) fires for `online-boutique/frontend`, then `CPUThrottlingHigh` (warning) for the same pod is suppressed. The engineer sees one critical alert, not ten cascading warnings.

## k3s False-Positive Alerts

The kube-prometheus-stack ships with built-in rules that assume standard Kubernetes component names. k3s combines many components into a single binary and exposes them differently:

| Alert | Why it fires on k3s | Production fix |
|-------|--------------------|----|
| `KubeSchedulerDown` | k3s scheduler isn't a separate process with the standard endpoint | Silence or override the ServiceMonitor |
| `KubeControllerManagerDown` | Same — embedded in k3s binary | Silence or override |
| `KubeProxyDown` | k3s uses kube-proxy differently | Silence or override |

For a portfolio project, these are acceptable false positives. In production on k3s you would add specific silences or modify the ServiceMonitor targets to match k3s's actual endpoints.

## `send_resolved: true` — Closing the Loop

Without this setting, your on-call engineer gets paged when something breaks but never gets notified when it recovers. They have to keep checking manually — was that disk space issue fixed? Is that pod still crashing?

With `send_resolved: true`:
- Alert fires → `[FIRING] PodCrashLooping` email sent
- Pod recovers → `[RESOLVED] PodCrashLooping` email sent automatically
- Engineer knows the incident is over without checking

This is standard practice in production. The resolved notification is as important as the firing notification.

## ArgoCD `ignoreDifferences` vs `RespectIgnoreDifferences`

This project hit a subtle ArgoCD behaviour: the loki-stack chart auto-generates a Grafana datasource ConfigMap with `isDefault: true`. We needed to patch it to `isDefault: false` to prevent Grafana crashing.

**`ignoreDifferences`** alone: ArgoCD ignores the diff in its display (doesn't show it as OutOfSync) but still **applies** the chart's version of the resource on every sync — reverting our patch.

**`ignoreDifferences` + `RespectIgnoreDifferences=true` in syncOptions**: ArgoCD both ignores the diff AND skips applying the ignored fields during sync — our patch survives.

```yaml
ignoreDifferences:
  - group: ""
    kind: ConfigMap
    name: loki-loki-stack
    jsonPointers:
      - /data

syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true   # ← this is what makes it stick
```

## Interview Talking Points

- "AlertManager and Prometheus are separate by design — Prometheus evaluates rules and detects conditions, AlertManager handles routing and notification. This means you can have multiple Prometheus servers all funnelling alerts to one AlertManager which handles all routing centrally"
- "We configured Gmail SMTP using a Kubernetes Secret mounted as a file — the password is never in Git. AlertManager reads it from /etc/alertmanager/secrets/ at runtime. If someone gets access to our Git repo, they can't read the SMTP password"
- "The null receiver is standard practice — Watchdog fires constantly as a heartbeat proving the pipeline works. You route it to null so it doesn't page the on-call engineer every 4 hours, but it still proves alerting is functioning"
- "We received real alerts from a real incident — KubeDeploymentReplicasMismatch fired when Grafana was in CrashLoopBackOff, then auto-resolved when we fixed it. The send_resolved: true config is what closes the loop — engineers know the incident is over without manual checks"
- "k3s generates false-positive alerts for KubeSchedulerDown and KubeControllerManagerDown because those components are embedded in the k3s binary rather than running as separate processes with standard endpoints. In production you'd create silences or modify the ServiceMonitor targets"
- "Inhibit rules prevent alert storms — when a node goes down, dozens of cascading warnings would fire. Inhibit rules suppress lower-severity alerts when a critical is already firing for the same namespace and alertname, so on-call sees one critical alert, not fifty"
