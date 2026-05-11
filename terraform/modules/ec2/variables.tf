variable "project" {
  description = "Project name used as a prefix on all resources"
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where instances will be created"
  type        = string
}

variable "public_subnet_id" {
  description = "ID of the public subnet where instances will be placed"
  type        = string
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for the Jenkins server"
  type        = string
}

variable "k3s_instance_type" {
  description = "EC2 instance type for the k3s Kubernetes node"
  type        = string
}

variable "key_pair_name" {
  description = "Name of the AWS key pair for SSH access"
  type        = string
}

variable "jenkins_iam_profile" {
  description = "IAM instance profile name for the Jenkins server"
  type        = string
}

variable "k3s_iam_profile" {
  description = "IAM instance profile name for the k3s node"
  type        = string
}
