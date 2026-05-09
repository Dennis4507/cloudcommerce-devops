terraform {
  backend "s3" {
    bucket       = "cloudcommerce-tfstate-927311782753"
    key          = "dev/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
    profile      = "cloudcommerce"
  }
}
