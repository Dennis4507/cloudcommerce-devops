output "jenkins_public_ip" {
  description = "Elastic IP address of the Jenkins server (static)"
  value       = aws_eip.jenkins.public_ip
}

output "jenkins_public_dns" {
  description = "Public DNS of the Jenkins server"
  value       = aws_eip.jenkins.public_dns
}

output "k3s_public_ip" {
  description = "Elastic IP address of the k3s Kubernetes node (static)"
  value       = aws_eip.k3s.public_ip
}

output "k3s_public_dns" {
  description = "Public DNS of the k3s Kubernetes node"
  value       = aws_eip.k3s.public_dns
}
