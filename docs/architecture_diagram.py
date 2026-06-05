#!/usr/bin/env python3
"""
CloudCommerce DevOps — Architecture Diagram
=============================================
Single comprehensive diagram.

Run from WSL:
    source ~/diagrams-env/bin/activate
    cd "/mnt/c/Users/OnlyM/Devops Project/cloudcommerce-devops/docs"
    python architecture_diagram.py

Output:
    cloudcommerce_architecture.png
"""

import os
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2, ECR
from diagrams.aws.network import InternetGateway
from diagrams.aws.security import IAM, SecretsManager
from diagrams.onprem.ci import Jenkins
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.monitoring import Grafana, Prometheus, PrometheusOperator
from diagrams.onprem.vcs import Github
from diagrams.onprem.iac import Terraform, Ansible
from diagrams.k8s.compute import Pod
from diagrams.k8s.network import Ingress
from diagrams.k8s.ecosystem import Helm

OUT = os.path.dirname(os.path.abspath(__file__))

# ══════════════════════════════════════════════════════════════════
# Styling
# ══════════════════════════════════════════════════════════════════

# Nodes: big icons, bold label below (never on the icon)
NODE_ATTR = {
    "fontsize":  "19",
    "fontname":  "Helvetica-Bold",
    "width":     "3.0",
    "height":    "3.8",   # extra height so label clears below the icon
    "fixedsize": "false", # grow if the label needs more room
    "labelloc":  "b",     # label at BOTTOM
    "imagepos":  "tc",    # icon at TOP-CENTRE
    "imagescale": "true",
}

# Graph: title at top (TB direction required for labelloc="t" to mean TOP)
GRAPH_ATTR = {
    "label":     "CloudCommerce  —  Full DevOps Architecture  (AWS eu-central-1)",
    "labelloc":  "t",      # title at the very top
    "labeljust": "c",
    "fontsize":  "46",     # large title
    "fontname":  "Helvetica-Bold",
    "bgcolor":   "white",
    "pad":       "1.2",
    "nodesep":   "0.9",    # horizontal gap between nodes
    "ranksep":   "2.2",    # vertical gap between ranks
    "splines":   "spline",
    "dpi":       "250",
    "concentrate": "false",
}

# Cluster fill colours
C_IAC  = {"style": "filled", "bgcolor": "#fff8e1",
           "fontsize": "20", "fontname": "Helvetica-Bold", "fontcolor": "#bf360c"}
C_AWS  = {"style": "filled", "bgcolor": "#e3f2fd",
           "fontsize": "24", "fontname": "Helvetica-Bold", "fontcolor": "#0d47a1"}
C_VPC  = {"style": "filled", "bgcolor": "#bbdefb",
           "fontsize": "20", "fontname": "Helvetica-Bold", "fontcolor": "#1565c0"}
C_SVC  = {"style": "filled", "bgcolor": "#dce8f5",
           "fontsize": "19", "fontname": "Helvetica-Bold", "fontcolor": "#1a237e"}
C_K3S  = {"style": "filled", "bgcolor": "#ede7f6",
           "fontsize": "20", "fontname": "Helvetica-Bold", "fontcolor": "#4527a0"}
C_APPS = {"style": "filled", "bgcolor": "#e8f5e9",
           "fontsize": "18", "fontname": "Helvetica-Bold", "fontcolor": "#1b5e20"}
C_MON  = {"style": "filled", "bgcolor": "#fce4ec",
           "fontsize": "18", "fontname": "Helvetica-Bold", "fontcolor": "#880e4f"}

# ══════════════════════════════════════════════════════════════════
# Edge helpers
# ══════════════════════════════════════════════════════════════════

def dev_push(label="git push"):
    """Dark grey developer-to-github edge."""
    return Edge(color="#212121", penwidth="3.2", label=label,
                fontsize="16", fontcolor="#212121", fontname="Helvetica-Bold")

def ci(label=""):
    """Orange CI pipeline arrow."""
    return Edge(color="#e65100", penwidth="4.0", label=label,
                fontsize="15", fontcolor="#e65100", fontname="Helvetica-Bold")

def ci_nc(label=""):
    """Orange CI arrow, constraint=false (backward/cross edges)."""
    return Edge(color="#e65100", penwidth="4.0", label=label,
                fontsize="15", fontcolor="#e65100", fontname="Helvetica-Bold",
                constraint="false")

def gitops(label=""):
    """Green GitOps arrow."""
    return Edge(color="#1b5e20", penwidth="4.0", label=label,
                fontsize="15", fontcolor="#1b5e20", fontname="Helvetica-Bold")

def gitops_nc(label=""):
    """Green GitOps arrow, constraint=false."""
    return Edge(color="#1b5e20", penwidth="4.0", label=label,
                fontsize="15", fontcolor="#1b5e20", fontname="Helvetica-Bold",
                constraint="false")

def monitor(label=""):
    """Purple metrics arrow."""
    return Edge(color="#6a1b9a", penwidth="3.2", label=label,
                fontsize="15", fontcolor="#6a1b9a", fontname="Helvetica-Bold")

def logs(label="logs"):
    """Blue log-shipping arrow."""
    return Edge(color="#1565c0", penwidth="3.2", label=label,
                fontsize="15", fontcolor="#1565c0", fontname="Helvetica-Bold")

def infra(label=""):
    """
    Brown dashed IaC/infrastructure arrow — more pronounced than before.
    constraint=false so these decorative edges never distort the main layout.
    """
    return Edge(color="#4e342e", penwidth="3.0", style="dashed", label=label,
                fontsize="15", fontcolor="#4e342e", fontname="Helvetica-Bold",
                constraint="false", arrowsize="1.4")

def network(label=""):
    """Blue solid network-routing arrow, no rank constraint."""
    return Edge(color="#0277bd", penwidth="3.0", label=label,
                fontsize="15", fontcolor="#0277bd", fontname="Helvetica-Bold",
                constraint="false")


# ══════════════════════════════════════════════════════════════════
# Diagram — direction TB creates nested-squares layout:
#   top row = Developer / GitHub / IaC
#   bottom dominant box = AWS eu-central-1
#     left inner box = VPC (Jenkins CI + k3s EC2)
#     right inner box = k3s Cluster (ArgoCD → apps → monitoring)
#     bottom inner box = AWS Services (ECR · IAM · IGW · Secrets)
# ══════════════════════════════════════════════════════════════════
with Diagram(
    "",   # empty — real title lives in graph_attr["label"] at the top
    filename=os.path.join(OUT, "cloudcommerce_architecture"),
    show=False,
    outformat="png",
    graph_attr=GRAPH_ATTR,
    node_attr=NODE_ATTR,
    direction="TB",
):

    # ── Top row: source + IaC ─────────────────────────────────────
    developer = Github("Developer")
    github    = Github("GitHub")

    with Cluster("IaC  (run once / on change)", graph_attr=C_IAC):
        terraform = Terraform("Terraform")
        ansible   = Ansible("Ansible")

    # ── AWS eu-central-1 ─────────────────────────────────────────
    with Cluster("AWS  eu-central-1", graph_attr=C_AWS):

        # Inner box 1: VPC with the two EC2 instances
        with Cluster("VPC  —  Public Subnet  (10.0.1.0/24)", graph_attr=C_VPC):
            jenkins = Jenkins("Jenkins CI\n:8080  (t2.medium)")
            k3s_ec2 = EC2("k3s EC2\nt2.large  :6443")

        # Inner box 2: k3s Kubernetes cluster
        with Cluster("k3s  —  single-node Kubernetes", graph_attr=C_K3S):
            argocd = ArgoCD("ArgoCD\n:30080")
            helm   = Helm("Helm")

            # Inner box 3: Online Boutique microservices
            with Cluster("apps namespace  —  Online Boutique", graph_attr=C_APPS):
                ingress  = Ingress("Nginx Ingress")
                frontend = Pod("frontend")
                backends = Pod("10 microservices")
                loadgen  = Pod("loadgenerator")

            # Inner box 4: Observability stack
            with Cluster("monitoring namespace", graph_attr=C_MON):
                prom  = Prometheus("Prometheus")
                graf  = Grafana("Grafana\n:30030")
                alert = PrometheusOperator("AlertManager\n:30031")
                loki  = PrometheusOperator("Loki Stack")
                exsec = PrometheusOperator("Ext. Secrets")

        # Inner box 5: Shared AWS services
        with Cluster("AWS Services", graph_attr=C_SVC):
            igw = InternetGateway("Internet Gateway")
            ecr = ECR("ECR  (private)")
            iam = IAM("IAM Roles")
            sm  = SecretsManager("Secrets Manager")

    # ══════════════════════════════════════════════════════════════
    # Edges — full story in numbered steps
    # ══════════════════════════════════════════════════════════════

    # Developer → GitHub
    developer >> dev_push() >> github

    # IaC provisions / configures (dashed, no rank constraint)
    terraform >> infra("provisions") >> jenkins
    terraform >> infra()             >> k3s_ec2
    terraform >> infra()             >> ecr
    terraform >> infra()             >> iam
    ansible   >> infra("configures") >> jenkins
    ansible   >> infra()             >> k3s_ec2
    ansible   >> infra()             >> argocd

    # Network (no rank constraint)
    igw >> network("routes") >> jenkins
    igw >> network()         >> k3s_ec2
    iam >> infra()           >> jenkins
    iam >> infra()           >> k3s_ec2

    # ① CI Pipeline (orange)
    github  >> ci("① webhook")        >> jenkins
    jenkins >> ci("② build + push")   >> ecr
    jenkins >> ci_nc("③ update tag")  >> github    # backward arc — nc = no constraint

    # ④ GitOps (green)
    github   >> gitops("④ ArgoCD polls")      >> argocd
    argocd   >> gitops_nc("⑤ pull image")     >> ecr     # cross to AWS Services
    argocd   >> gitops()                       >> helm
    helm     >> gitops()                       >> ingress
    ingress  >> gitops("⑥ deploy")             >> frontend
    frontend >> gitops()                       >> backends
    loadgen  >> gitops_nc("generate load")     >> ingress

    # ⑦ Observability (purple metrics + blue logs)
    backends >> monitor("⑦ metrics") >> prom
    backends >> logs("logs")          >> loki
    prom     >> monitor()             >> graf
    prom     >> monitor("alerts")     >> alert
    loki     >> monitor()             >> graf

    # Secrets sync
    exsec >> infra("sync secrets") >> sm

    # ECR token auto-refresh via IAM instance role (cron every 6 h)
    k3s_ec2 >> infra("token refresh  cron/6h") >> ecr


print("\nDone!  →  docs/cloudcommerce_architecture.png")
print("Open in Chrome/Edge — Ctrl+scroll to zoom, 250 DPI stays sharp.")
