output "repository_urls" {
  description = "Map of service names to their ECR repository URLs"
  value = {
    for service, repo in aws_ecr_repository.services :
    service => repo.repository_url
  }
}

output "repository_arns" {
  description = "Map of service names to their ECR repository ARNs"
  value = {
    for service, repo in aws_ecr_repository.services :
    service => repo.arn
  }
}
