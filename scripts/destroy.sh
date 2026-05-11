#!/bin/bash

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo ""
echo -e "${RED}========================================${NC}"
echo -e "${RED}   CLOUDCOMMERCE DESTROY SCRIPT${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}This will destroy ALL AWS infrastructure.${NC}"
echo -e "${YELLOW}Make sure you have completed the checklist below.${NC}"
echo ""

echo -e "${RED}PRE-DESTROY CHECKLIST — confirm each one:${NC}"
echo ""

read -p "[ ] Have you taken screenshots of the live application? (y/n): " s1
read -p "[ ] Have you screenshotted the Jenkins pipeline run? (y/n): " s2
read -p "[ ] Have you screenshotted ArgoCD showing all services healthy? (y/n): " s3
read -p "[ ] Have you screenshotted Grafana dashboards with real metrics? (y/n): " s4
read -p "[ ] Have you updated the README with latest screenshots? (y/n): " s5
read -p "[ ] Have you run git add, commit, and push? (y/n): " s6

echo ""

if [[ "$s1" != "y" || "$s2" != "y" || "$s3" != "y" || "$s4" != "y" || "$s5" != "y" || "$s6" != "y" ]]; then
  echo -e "${RED}Checklist incomplete. Go back and complete all items before destroying.${NC}"
  echo ""
  exit 1
fi

echo -e "${YELLOW}All items confirmed. Proceeding to destroy in 10 seconds...${NC}"
echo -e "${YELLOW}Press Ctrl+C NOW to cancel.${NC}"
echo ""
sleep 10

echo -e "${RED}Destroying infrastructure...${NC}"
echo ""

cd "$(dirname "$0")/../terraform/environments/dev"

terraform destroy -auto-approve

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   DESTROY COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Verifying nothing is left running...${NC}"
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=cloudcommerce" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table \
  --profile cloudcommerce

echo ""
echo -e "${GREEN}Done. All resources destroyed. Costs stopped.${NC}"
echo -e "${GREEN}Your code and documentation remain safe on GitHub.${NC}"
echo ""
