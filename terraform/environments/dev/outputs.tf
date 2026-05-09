output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "jenkins_public_ip" {
  description = "Public IP address of the Jenkins server"
  value       = module.compute.jenkins_public_ip
}

output "k3s_public_ip" {
  description = "Public IP address of the k3s Kubernetes node"
  value       = module.compute.k3s_public_ip
}

output "ecr_repository_urls" {
  description = "ECR repository URLs for all services"
  value       = module.ecr.repository_urls
}
