# The unknown-bundle guard.
#
# It is a lifecycle precondition on terraform_data.validate_bundles, and
# expect_failures can only name objects in the configuration under test — so
# these tests run from this module's own directory, where that resource is
# top-level. There is no `module {}` block and no calling root.
#
# This guard is not a variable validation: a bundle name is wrong only relative
# to the catalog, so it cannot be checked without both variables in hand, and
# the module's floor (>= 1.5.0) predates cross-variable validation conditions.

mock_provider "aws" {}

variables {
  environment = "test"
  aws_region  = "eu-central-1"
  default_az  = "eu-central-1a"

  network_config = {
    vpc_cidr = "10.8.0.0/16"
    public_subnets = {
      "eu-central-1a" = {
        cidr_block = "10.8.1.0/24"
        az         = "eu-central-1a"
      }
    }
  }

  security_group_rules    = {}
  route53_zone_id         = "Z00000000000000000TEST"
  cinc_ssm_parameter_name = "/test/cinc-validator"
  loki_ssm_parameter_name = "/test/loki-token"
  cinc_server_url         = "https://cinc.test.invalid/organizations/test"
  ssh_key_pairs           = { "dev" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST dev@test" }
}

run "unknown_bundle_name_stops_the_plan" {
  command = plan

  variables {
    # "s3-media-dve" — transposed, the realistic form of this mistake.
    instances = {
      "dev" = {
        instance_type  = "t3.micro"
        volume_size_gb = 20
        az             = "eu-central-1a"
        fqdn           = "dev.ec2.eu-central-1.test.invalid"
        key_name       = "dev"
        aws_access     = ["s3-media-dve"]
      }
    }
    access_bundles = {
      "s3-media-dev" = {
        description     = "correctly spelled"
        policy_arns     = []
        allowed_actions = ["s3:*"]
      }
    }
  }

  expect_failures = [terraform_data.validate_bundles]
}

# The same shape with the name spelled right must plan. Without this, a guard that
# rejected everything would still pass the case above.
run "correctly_spelled_bundle_plans" {
  command = plan

  variables {
    instances = {
      "dev" = {
        instance_type  = "t3.micro"
        volume_size_gb = 20
        az             = "eu-central-1a"
        fqdn           = "dev.ec2.eu-central-1.test.invalid"
        key_name       = "dev"
        aws_access     = ["s3-media-dev"]
      }
    }
    access_bundles = {
      "s3-media-dev" = {
        description     = "correctly spelled"
        policy_arns     = ["arn:aws:iam::111122223333:policy/s3-media-dev"]
        allowed_actions = ["s3:*"]
      }
    }
  }
}
