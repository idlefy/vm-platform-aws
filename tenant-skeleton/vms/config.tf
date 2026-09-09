locals {
  environment = "dev"

  # The single AWS provider's own region. It does NOT decide where anything lands:
  # every regional resource in modules/ec2 sets `region = var.aws_region` itself,
  # and the global ones (IAM, Route53) have no region at all. This only picks the
  # endpoint used for those global calls and for `data.aws_caller_identity`.
  #
  # It must name a region the account can actually reach. An organisation may
  # allowlist regions with an SCP, in which case an arbitrary choice fails every
  # call — and a denied region reports `opt-in-not-required` exactly like an
  # enabled one, so opt-in status does not reveal it. `cd cinc && make
  # add-region REGION=<region>` is the supported way to add one.
  provider_region = "us-east-1"

  # Shared security group rules (same for all regions)
  shared_security_group_rules = {
    ssh = {
      type        = "ingress"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "SSH access"
    }
    http = {
      type        = "ingress"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTP access"
    }
    https = {
      type        = "ingress"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTPS access"
    }
  }

  # --- Per-region configuration ---

  regions = {
    # ==================== us-east-1 ====================
    "us-east-1" = {
      network_config = {
        vpc_cidr = "10.8.0.0/16"
        public_subnets = {
          "us-east-1a" = {
            cidr_block = "10.8.1.0/24"
            az         = "us-east-1a"
          }
          "us-east-1b" = {
            cidr_block = "10.8.2.0/24"
            az         = "us-east-1b"
          }
          "us-east-1c" = {
            cidr_block = "10.8.3.0/24"
            az         = "us-east-1c"
          }
          "us-east-1d" = {
            cidr_block = "10.8.4.0/24"
            az         = "us-east-1d"
          }
        }
      }

      default_az = "us-east-1a"

    }

    # ==================== eu-north-1 ====================
    "eu-north-1" = {
      network_config = {
        vpc_cidr = "10.8.0.0/16"
        public_subnets = {
          "eu-north-1a" = {
            cidr_block = "10.8.1.0/24"
            az         = "eu-north-1a"
          }
          "eu-north-1b" = {
            cidr_block = "10.8.2.0/24"
            az         = "eu-north-1b"
          }
        }
      }

      default_az = "eu-north-1a"

    }

    # ==================== eu-central-1 ====================
    "eu-central-1" = {
      network_config = {
        vpc_cidr = "10.8.0.0/16"
        public_subnets = {
          "eu-central-1a" = {
            cidr_block = "10.8.1.0/24"
            az         = "eu-central-1a"
          }
          "eu-central-1b" = {
            cidr_block = "10.8.2.0/24"
            az         = "eu-central-1b"
          }
          "eu-central-1c" = {
            cidr_block = "10.8.3.0/24"
            az         = "eu-central-1c"
          }
        }
      }

      default_az = "eu-central-1a"

    }
  }
}
