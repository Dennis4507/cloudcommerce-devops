variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name used to tag and namespace all resources"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name used as a prefix on all resources"
  type        = string
  default     = "cloudcommerce"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for the Jenkins server"
  type        = string
  default     = "t2.micro"
}

variable "k3s_instance_type" {
  description = "EC2 instance type for the k3s Kubernetes node"
  type        = string
  default     = "t3.medium"
}

variable "key_pair_name" {
  description = "Name of the AWS key pair for SSH access to EC2 instances"
  type        = string
  default     = "cloudcommerce-dev-key"
}
