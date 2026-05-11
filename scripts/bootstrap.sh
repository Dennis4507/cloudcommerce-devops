#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   CLOUDCOMMERCE BOOTSTRAP SCRIPT${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}This will provision all AWS infrastructure.${NC}"
echo ""

echo -e "${YELLOW}Checking prerequisites...${NC}"

command -v terraform &>/dev/null || { echo "Terraform not found. Install it first."; exit 1; }
command -v aws &>/dev/null || { echo "AWS CLI not found. Install it first."; exit 1; }
command -v ansible &>/dev/null || { echo "Ansible not found. Install it first."; exit 1; }

echo -e "${GREEN}All prerequisites found.${NC}"
echo ""

echo -e "${YELLOW}Verifying AWS credentials...${NC}"
aws sts get-caller-identity --profile cloudcommerce
echo ""

read -p "Correct AWS account and user? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "Aborted. Check your AWS profile configuration."
  exit 1
fi

echo ""
echo -e "${YELLOW}Initialising Terraform...${NC}"
cd "$(dirname "$0")/../terraform/environments/dev"
terraform init

echo ""
echo -e "${YELLOW}Running Terraform plan...${NC}"
terraform plan

echo ""
read -p "Plan looks good? Apply now? (y/n): " apply_confirm
if [[ "$apply_confirm" != "y" ]]; then
  echo "Aborted at plan stage. No resources created."
  exit 0
fi

echo ""
echo -e "${YELLOW}Applying infrastructure...${NC}"
terraform apply -auto-approve

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   INFRASTRUCTURE READY${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Outputs:${NC}"
terraform output
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. SSH into Jenkins:  ssh -i terraform/keys/cloudcommerce-dev-key ubuntu@\$(terraform output -raw jenkins_public_ip)"
echo "  2. SSH into k3s node: ssh -i terraform/keys/cloudcommerce-dev-key ubuntu@\$(terraform output -raw k3s_public_ip)"
echo "  3. Run Ansible playbooks to configure servers"
echo ""
