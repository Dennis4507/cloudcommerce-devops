# VPC Networking — Deep Dive

## What is a VPC?

VPC stands for Virtual Private Cloud. AWS is a massive shared infrastructure used by millions of companies worldwide. A VPC is your private, isolated section of that infrastructure — walled off completely from everyone else.

Think of AWS as a city. Your VPC is the building you rent in that city. Other tenants cannot see inside your building, cannot access your resources, and cannot interfere with your network. You control everything inside.

## Why We Need One

Without a VPC, your resources would be exposed on a flat shared network. Every EC2 instance, database, and service needs to live inside a defined network boundary. AWS requires it — you cannot create an EC2 instance without a VPC.

For CloudCommerce, our VPC (`cloudcommerce-dev-vpc`) is the private network where Jenkins, our k3s Kubernetes node, and all future resources live.

## CIDR Blocks — The Address Space

```
VPC CIDR:             10.0.0.0/16   → 65,536 possible IP addresses
Public subnet CIDR:   10.0.1.0/24   → 256 addresses (Jenkins + k3s live here)
Private subnet CIDR:  10.0.2.0/24   → 256 addresses (future databases)
```

The `/16` and `/24` are subnet masks defining how many addresses are available. We define a large VPC range upfront because adding address space later is painful. It costs nothing to reserve it.

## Subnets — Floors in the Building

A subnet divides the VPC into sections with different access rules — like floors in a building.

**Public Subnet** — has a path to the internet. Servers here get public IP addresses automatically. Jenkins and the k3s node live here because they need to be reachable — Jenkins for GitHub webhooks, k3s for serving the application to users.

**Private Subnet** — no direct internet access. Resources here can only be reached from inside the VPC. Databases and internal services belong here. If the application is compromised, an attacker cannot directly reach the database because it has no public path.

## Internet Gateway — The Front Door

The internet gateway is the single controlled connection between your VPC and the public internet. Without it, your VPC is completely sealed — no inbound traffic, no outbound traffic. Servers couldn't download updates, receive requests, or reach external APIs.

One internet gateway serves the entire VPC. It is not a server or a bottleneck — it is a logical construct that AWS manages.

## Route Table — The GPS

A route table contains rules that tell traffic where to go. Our public route table has one rule:

```
Destination: 0.0.0.0/0  →  Target: Internet Gateway
```

This means: send all outbound traffic (to any destination on the internet) through the internet gateway. The route table association links this rule specifically to the public subnet. Without the association, the rule exists but applies to nothing.

The private subnet has no route to the internet gateway — so traffic from there has nowhere to go externally.

## Security Groups — The Bouncers

A security group is a firewall attached to an individual server. It checks every incoming and outgoing packet against a list of rules.

**Key difference from route tables:**
```
Route table  = WHERE does traffic go? (direction)
Security group = WHO is allowed through? (permission)
```

Both must say yes for traffic to flow:
1. Route table gives it a path
2. Security group allows it through

**Jenkins security group rules:**
```
Port 22   → SSH (admin access to manage the server)
Port 8080 → Jenkins web UI (pipeline dashboard)
All outbound → so Jenkins can reach GitHub, ECR, the internet
```

**k3s security group rules:**
```
Port 22   → SSH
Port 80   → HTTP (application traffic)
Port 443  → HTTPS (secure application traffic)
Port 6443 → Kubernetes API (kubectl commands from your machine)
Port 30080 → ArgoCD UI (GitOps dashboard)
All outbound → so k3s can pull images from ECR
```

Anything not listed is automatically blocked. An attacker scanning random ports finds nothing open.

## The Full Journey of a User Request

```
User in Berlin types your domain
         ↓
DNS resolves to your k3s public IP
         ↓
Packet arrives at Internet Gateway  ← enters the building
         ↓
Route table: "Port 80 going to k3s IP → route to public subnet"
         ↓
Security group: "Port 80 is allowed → let it through"
         ↓
k3s node receives the request
         ↓
Kubernetes routes to the frontend service
         ↓
frontend calls productcatalog, cart, currency internally
         ↓
Response travels back through the same path
         ↓
User sees the Online Boutique webpage
```

## Interview Talking Points

- "I chose a public/private subnet split to follow the principle of least exposure — only resources that need internet access are in the public subnet"
- "Security groups are stateful — if you allow inbound port 80, the response traffic is automatically allowed back out without needing an explicit outbound rule"
- "One internet gateway per VPC is an AWS hard limit — it is not a single point of failure because AWS manages its availability internally"
- "Route tables and security groups work at different layers — route tables at the subnet level, security groups at the instance level"
