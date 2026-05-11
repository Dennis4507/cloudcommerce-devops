# ----------------------------------------
# JENKINS IAM ROLE
# ----------------------------------------

resource "aws_iam_role" "jenkins" {
  name = "${var.project}-${var.environment}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "jenkins_ecr" {
  name        = "${var.project}-${var.environment}-jenkins-ecr-policy"
  description = "Allows Jenkins to build, push and pull images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ecr" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.jenkins_ecr.arn
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project}-${var.environment}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

# ----------------------------------------
# K3S IAM ROLE
# ----------------------------------------

resource "aws_iam_role" "k3s" {
  name = "${var.project}-${var.environment}-k3s-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "k3s_ecr" {
  name        = "${var.project}-${var.environment}-k3s-ecr-policy"
  description = "Allows k3s node to pull images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "k3s_ecr" {
  role       = aws_iam_role.k3s.name
  policy_arn = aws_iam_policy.k3s_ecr.arn
}

resource "aws_iam_instance_profile" "k3s" {
  name = "${var.project}-${var.environment}-k3s-profile"
  role = aws_iam_role.k3s.name
}
