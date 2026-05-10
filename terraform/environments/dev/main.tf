module "vpc" {
  source = "../../modules/vpc"

  project             = var.project
  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  aws_region          = var.aws_region
}

module "iam" {
  source = "../../modules/iam"

  project     = var.project
  environment = var.environment
}

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment
}

module "compute" {
  source = "../../modules/compute"

  project               = var.project
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  public_subnet_id      = module.vpc.public_subnet_id
  jenkins_instance_type = var.jenkins_instance_type
  k3s_instance_type     = var.k3s_instance_type
  key_pair_name         = var.key_pair_name
  jenkins_iam_profile   = module.iam.jenkins_instance_profile
  k3s_iam_profile       = module.iam.k3s_instance_profile
}
