terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = {
      Environment = local.environment
      Region      = "us-east-1"
      ManagedBy   = "Terraform"
      Account     = var.account_name
    }
  }
}

module "security" {
  source = "./modules/security-vm"

  environment  = local.environment
  aws_region   = "us-east-1"
  account_name = var.account_name

  vpc_cidr    = "10.0.0.0/16"
  subnet_cidr = "10.0.1.0/24"
  subnet_az   = "us-east-1a"

  ami_id          = "ami-04eaa218f1349d88b" # Ubuntu 24.04 noble 2026-03-21
  ssh_key_pairs   = var.ssh_key_pairs
  master_ssh_keys = var.master_ssh_keys
  instances       = local.instances
  route53_zone_id = var.route53_zone_id
}
