# Post 04 — The Two Firewalls Nobody Explains

---

I configured the Kubernetes Service correctly.

Grafana still wasn't accessible.

I'm building a full DevOps platform on AWS — k3s Kubernetes, Jenkins CI/CD, ArgoCD GitOps, full observability stack on a 12-microservice ecommerce application. After deploying Grafana, I set up a NodePort Service on port 30030. All pods were Running. Everything looked fine.

Browser said: ERR_CONNECTION_TIMED_OUT.

I spent time checking the Kubernetes Service. It was correct. I checked the pod. It was healthy. I checked the logs. No errors.

The problem was somewhere I wasn't looking.

When you deploy on AWS, traffic to your application passes through two completely separate access control layers:

**Layer 1 — AWS Security Group:** Controls what traffic can reach your EC2 instance from the internet. Managed in AWS. Has nothing to do with Kubernetes.

**Layer 2 — Kubernetes Service:** Controls how traffic is routed from the EC2 host port to the pod. Managed in Kubernetes. Has nothing to do with AWS.

Both must be open. If the Security Group is closed, traffic never reaches the EC2 instance — Kubernetes never even sees the request. You can have a perfect Kubernetes configuration and still get a timeout.

I had the Kubernetes Service configured. I had the Terraform code written for the Security Group rule. But I hadn't run `terraform apply`. The rule existed in code but not in AWS.

Two minutes in the AWS Console. Grafana loaded immediately.

Here's what I'm curious about though:

Is manually adding Security Group rules in the console ever acceptable in a production environment? We had the Terraform code — we just hadn't applied it. Some teams treat the console as a valid "emergency escape hatch." Others treat any manual change as a policy violation.

Where do you draw the line? Console for emergencies only? Never? Or does it depend on the team?

#DevOps #Kubernetes #AWS #Terraform #CloudEngineering #LearningInPublic
