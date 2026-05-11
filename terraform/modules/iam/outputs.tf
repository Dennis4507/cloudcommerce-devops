output "jenkins_instance_profile" {
  description = "IAM instance profile name for the Jenkins EC2 instance"
  value       = aws_iam_instance_profile.jenkins.name
}

output "k3s_instance_profile" {
  description = "IAM instance profile name for the k3s EC2 instance"
  value       = aws_iam_instance_profile.k3s.name
}

output "jenkins_role_arn" {
  description = "ARN of the Jenkins IAM role"
  value       = aws_iam_role.jenkins.arn
}

output "k3s_role_arn" {
  description = "ARN of the k3s IAM role"
  value       = aws_iam_role.k3s.arn
}
