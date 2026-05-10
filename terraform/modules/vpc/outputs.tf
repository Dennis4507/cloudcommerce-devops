output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet"
  value       = aws_subnet.private.id
}

output "jenkins_security_group_id" {
  description = "Security group ID for the Jenkins server"
  value       = aws_security_group.jenkins.id
}

output "k3s_security_group_id" {
  description = "Security group ID for the k3s node"
  value       = aws_security_group.k3s.id
}
