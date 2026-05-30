# AWS Secrets Manager + External Secrets Operator — Deep Dive

## The Problem With Manual Secrets

Every Kubernetes secret created with `kubectl create secret` has a fatal flaw — it only exists in etcd on the cluster. It is not in Git (by design — secrets shouldn't be in Git). It has no backup. It has no audit trail. And it will not survive:

- A Terraform destroy and recreate
- A cluster reinstall
- A new engineer rebuilding infrastructure from scratch
- An EBS volume failure

The moment something wipes the cluster, the secret is gone. Someone has to remember what it was, find it, and recreate it manually. That is the operational risk of manual secrets.

## The Solution — Separate Secret Storage from Secret Consumption

The production answer is to store secrets in a dedicated secrets management system that exists independently of any Kubernetes cluster. The cluster then fetches secrets from that system at runtime.

```
Secrets live here (permanent):     Kubernetes fetches from here (ephemeral):
AWS Secrets Manager            →   External Secrets Operator   →   Kubernetes Secret
(survives cluster rebuilds)        (syncs automatically)           (recreated on demand)
```

If the cluster is destroyed and rebuilt:
1. ArgoCD deploys the ExternalSecret manifest from Git
2. ESO reads it and connects to AWS Secrets Manager
3. AWS Secrets Manager returns the secret value
4. ESO creates the Kubernetes secret automatically
5. AlertManager starts healthy

Zero manual intervention. Zero one person remembering a password.

## AWS Secrets Manager

AWS Secrets Manager is a managed service for storing secrets. Key properties:

| Feature | Detail |
|---------|--------|
| Storage | Encrypted at rest using AWS KMS |
| Access control | IAM policies — who can read which secrets |
| Audit trail | Every access logged in AWS CloudTrail |
| Versioning | Previous versions kept — enables rotation without downtime |
| Rotation | Automatic rotation via Lambda (for databases etc.) |
| Cost | ~$0.40/secret/month + $0.05 per 10,000 API calls |

**Secret naming convention — use paths:**
```
cloudcommerce/alertmanager-smtp      ← our secret
cloudcommerce/database-password      ← future secret
cloudcommerce/api-keys               ← future secret
```

The `/` creates a logical namespace. IAM policies can be scoped to `cloudcommerce/*` — granting access to all project secrets without listing them individually.

**Creating a secret:**
```bash
aws secretsmanager create-secret \
  --name cloudcommerce/alertmanager-smtp \
  --secret-string '{"gmail-password":"your-app-password"}' \
  --region eu-central-1
```

The `--secret-string` is JSON — multiple key-value pairs in one secret:
```json
{
  "gmail-password": "app-password-here",
  "smtp-host": "smtp.gmail.com",
  "smtp-port": "587"
}
```

## External Secrets Operator (ESO)

ESO is a Kubernetes operator that watches for `ExternalSecret` custom resources and syncs them from external secret stores (AWS Secrets Manager, HashiCorp Vault, Azure Key Vault, GCP Secret Manager, etc.) into Kubernetes Secrets.

**How it works:**
1. You define a `ClusterSecretStore` — tells ESO where to fetch secrets from (AWS Secrets Manager in our case)
2. You define an `ExternalSecret` — tells ESO which secret to fetch and what Kubernetes Secret to create
3. ESO's controller pod watches for ExternalSecrets and reconciles — creates/updates the Kubernetes Secret
4. On the refresh interval (we set 1h), ESO re-fetches from AWS and updates the Kubernetes Secret if anything changed

**Key CRDs:**

```
ClusterSecretStore   — cluster-wide connection to a secret backend (one per cluster)
SecretStore          — namespace-scoped connection (one per namespace, more granular)
ExternalSecret       — "fetch this secret from that store and create this Kubernetes Secret"
```

## IAM Authentication — EC2 Instance Profile

The cleanest way to give ESO access to AWS Secrets Manager on EC2 is via the **instance profile**. No credentials in code, no access keys to rotate.

**How it works:**
- The k3s EC2 instance has an IAM role attached (instance profile)
- We added `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret` to that role
- ESO pods running on that instance inherit the role's permissions via the EC2 metadata service (`http://169.254.169.254/...`)
- No auth configuration needed in the ClusterSecretStore — ESO detects it automatically

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-central-1
      # No auth block — uses EC2 instance profile automatically
```

**IAM policy (least privilege):**
```hcl
resource "aws_iam_policy" "k3s_secrets_manager" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "arn:aws:secretsmanager:eu-central-1:*:secret:cloudcommerce/*"
      # Scoped to our project prefix only — not all secrets in the account
    }]
  })
}
```

## ExternalSecret — The Sync Definition

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: alertmanager-smtp-secret
  namespace: monitoring
spec:
  refreshInterval: 1h          # re-fetch from AWS every hour

  secretStoreRef:
    name: aws-secrets-manager  # which ClusterSecretStore to use
    kind: ClusterSecretStore

  target:
    name: alertmanager-smtp-secret   # name of the Kubernetes Secret to create
    creationPolicy: Owner            # ESO owns it — recreates if deleted

  data:
    - secretKey: gmail-password              # key in the Kubernetes Secret
      remoteRef:
        key: cloudcommerce/alertmanager-smtp # AWS Secrets Manager secret name
        property: gmail-password             # field in the JSON secret value
```

**`creationPolicy: Owner`** is important — it means ESO "owns" the Kubernetes Secret. If someone deletes the Kubernetes Secret manually (as we demonstrated), ESO recreates it on the next reconciliation cycle (within seconds to minutes). The secret cannot be permanently lost by accident.

## Demonstrating the Failure and Fix

We deleted the secret deliberately to show what a cluster rebuild looks like:

```bash
kubectl delete secret alertmanager-smtp-secret -n monitoring
# secret deleted

kubectl delete pod alertmanager-monitoring-kube-prometheus-alertmanager-0 -n monitoring
# pod restarts, tries to mount secret — fails
```

**The error:**
```
Warning  FailedMount  85s (x22 over 30m)  kubelet
MountVolume.SetUp failed for volume "secret-alertmanager-smtp-secret":
secret "alertmanager-smtp-secret" not found
```

AlertManager UI becomes unreachable. This is the production scenario after a cluster rebuild without secrets management.

**After ESO was deployed and synced:**
```bash
kubectl get externalsecret -n monitoring
NAME                       STORE                REFRESH INTERVAL   STATUS         READY
alertmanager-smtp-secret   aws-secrets-manager  1h                 SecretSynced   True

kubectl get secret alertmanager-smtp-secret -n monitoring
NAME                       TYPE     DATA   AGE
alertmanager-smtp-secret   Opaque   1      5m50s
```

AlertManager recovered automatically. No manual intervention.

## Secret Rotation

With AWS Secrets Manager, rotating the Gmail App Password requires:

1. Generate a new App Password in Google Account
2. Update the secret in AWS Secrets Manager:
```bash
aws secretsmanager update-secret \
  --secret-id cloudcommerce/alertmanager-smtp \
  --secret-string '{"gmail-password":"new-app-password"}' \
  --region eu-central-1
```
3. Wait up to 1 hour for ESO to sync (or force: `kubectl annotate externalsecret alertmanager-smtp-secret -n monitoring force-sync=$(date +%s) --overwrite`)
4. AlertManager picks up the new secret automatically on next pod restart

No `kubectl create secret`. No SSHing into the cluster. No one needs to know the password — they just update it in one place.

## Why Not Sealed Secrets?

Sealed Secrets is a popular alternative — secrets encrypted and committed to Git. The difference:

| | Sealed Secrets | AWS Secrets Manager + ESO |
|--|----------------|--------------------------|
| Secret location | Git (encrypted) | AWS (managed service) |
| Cluster dependency | Needs cluster's private key to decrypt | Independent of cluster |
| Rotation | Re-encrypt and commit | Update in AWS, ESO syncs |
| Audit trail | Git history | AWS CloudTrail |
| Cost | Free | ~$0.40/secret/month |
| AWS-native | No | Yes |

For AWS-based infrastructure, Secrets Manager + ESO is the more natural choice. The secret is managed in the same place as all other AWS resources. Sealed Secrets is better for multi-cloud or air-gapped environments.

## Interview Talking Points

- "We used AWS Secrets Manager with External Secrets Operator to manage the AlertManager SMTP secret. ESO watches for ExternalSecret resources and syncs secrets from AWS into Kubernetes automatically — so when we rebuild the cluster, ArgoCD deploys the ExternalSecret from Git and ESO recreates the Kubernetes secret without any manual steps"
- "Authentication to AWS Secrets Manager uses the EC2 instance profile — no credentials in code, no access keys to rotate. ESO inherits the IAM role permissions via the EC2 metadata service"
- "We demonstrated the failure first — deleted the secret, showed the FailedMount error, showed AlertManager unreachable. Then deployed ESO and showed SecretSynced: True and the pod recovering automatically. That's the before and after"
- "The IAM policy is scoped to cloudcommerce/* only — least privilege. The k3s node can read our project secrets but nothing else in the AWS account"
- "creationPolicy: Owner in the ExternalSecret means ESO owns the Kubernetes Secret. If someone accidentally deletes it, ESO recreates it within minutes — accidental deletion is not a crisis"
- "Secret rotation is: update in AWS Secrets Manager, wait up to 1 hour, ESO syncs automatically. No kubectl commands, no cluster access needed — the person rotating the secret never needs cluster credentials"
