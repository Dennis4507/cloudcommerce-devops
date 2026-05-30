# Post 09 — Terraform Destroyed My Server. Technically It Was Doing Exactly What I Asked.

---

I changed one line in Terraform.

It destroyed both my servers and rebuilt them from scratch.

Everything I had configured — gone.

📸 `docs/screenshots/87-terraform-forces-replacement-jenkins.png`
*— Lead thumbnail. The Terraform plan output showing "aws_instance.jenkins must be replaced" in red. That "-/+" symbol is one of the most alarming things you can see when you're about to run apply. Anyone who's used Terraform will feel their stomach drop.*

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, Prometheus, Grafana, Loki, AlertManager, all running a 12-microservice ecommerce application. Everything provisioned with Terraform as Infrastructure as Code.

I needed to change the instance type. Simple enough. I updated the value in Terraform, ran `terraform plan`, and saw this:

```
# aws_instance.k3s must be replaced
-/+ instance_type: "t3.medium" → "t3.large"  forces replacement
```

"Forces replacement" means Terraform destroys the existing instance and creates a brand new one. Not a restart. Not a resize. Destroy and recreate.

New EC2 instance. New AMI. Fresh operating system. Everything I had installed and configured — Jenkins pipelines, k3s cluster, ArgoCD, all running pods — wiped.

The fix was a `lifecycle` block in the Terraform resource:

```hcl
lifecycle {
  ignore_changes = [ami]
}
```

This tells Terraform: "if the AMI changes, don't replace the instance — leave it alone." The instance type change could then be applied as an in-place modification instead of a replacement.

But here's the thing — Terraform was not wrong. It was doing exactly what the configuration said to do. The AMI reference had drifted from what was on the instance, and Terraform's job is to make reality match the code. It did.

The mistake was mine. I ran `terraform apply` without fully understanding what "forces replacement" meant in practice.

📸 `docs/screenshots/91-new-instances-after-destroy.png`
*— New instances running after the replacement. Fresh. Clean. Empty. All that configuration work — gone and needing to be redone.*

I now read every `terraform plan` output line by line before applying — especially anything with `-/+` which means destroy and recreate.

But this makes me wonder:

Should Terraform require an explicit confirmation step for destructive operations like instance replacement — beyond just typing "yes"? Or is that on the engineer to understand the plan before applying?

Where does the tool's responsibility end and the engineer's begin?

#DevOps #Terraform #AWS #CloudEngineering #LearningInPublic #IaC
