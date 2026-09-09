# Input validation for this module, which is where it now lives.
#
# These are the 14 runs that used to sit in vms/tests/access_bundles.tftest.hcl
# against the calling root. Two things changed in the move and both are easy to
# get wrong:
#
#   - `var.instances` is map(object) here, not map(map(object)). Every fixture
#     loses its region key, and the validation expressions lose one `for` level.
#   - this module has five more required inputs than the root variable did, so
#     the `variables` block below supplies them once for every run.
#
# mock_provider replaces AWS entirely: no credentials, no backend, no network.

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

  instances      = {}
  access_bundles = {}
}

# --- access_bundles: seven ways a bundle is wrong --------------------------

run "empty_allowed_actions_is_rejected" {
  command = plan
  variables {
    access_bundles = { "b" = { description = "no ceiling", allowed_actions = [] } }
  }
  expect_failures = [var.access_bundles]
}

run "literal_star_is_rejected" {
  command = plan
  variables {
    access_bundles = { "b" = { description = "open ceiling", allowed_actions = ["*"] } }
  }
  expect_failures = [var.access_bundles]
}

run "bare_service_name_is_rejected" {
  command = plan
  variables {
    access_bundles = { "b" = { description = "no action", allowed_actions = ["s3"] } }
  }
  expect_failures = [var.access_bundles]
}

run "action_with_a_slash_is_rejected" {
  command = plan
  variables {
    access_bundles = { "b" = { description = "path, not action", allowed_actions = ["s3:Get/Object"] } }
  }
  expect_failures = [var.access_bundles]
}

run "iam_namespace_is_rejected" {
  command = plan
  variables {
    access_bundles = { "b" = { description = "escalation", allowed_actions = ["iam:PassRole"] } }
  }
  expect_failures = [var.access_bundles]
}

run "sts_namespace_is_rejected" {
  command = plan
  variables {
    access_bundles = { "b" = { description = "escalation", allowed_actions = ["sts:AssumeRole"] } }
  }
  expect_failures = [var.access_bundles]
}

run "ec2_instance_connect_namespace_is_rejected" {
  command = plan
  variables {
    access_bundles = { "b" = { description = "root on the VM", allowed_actions = ["ec2-instance-connect:SendSSHPublicKey"] } }
  }
  expect_failures = [var.access_bundles]
}

# --- VM names -------------------------------------------------------------
# One `for` level, not two: the key is the VM name directly.

run "uppercase_vm_name_is_rejected" {
  command = plan
  variables {
    instances = {
      "DevBox" = {
        instance_type  = "t3.micro"
        volume_size_gb = 20
        fqdn           = "devbox.test.invalid"
        key_name       = "dev"
      }
    }
  }
  expect_failures = [var.instances]
}

run "overlong_vm_name_is_rejected" {
  command = plan
  variables {
    instances = {
      "a-name-that-is-far-too-long-to-fit-in-an-iam-role" = {
        instance_type  = "t3.micro"
        volume_size_gb = 20
        fqdn           = "long.test.invalid"
        key_name       = "dev"
      }
    }
  }
  expect_failures = [var.instances]
}

# --- policy_group ---------------------------------------------------------

run "unknown_policy_group_is_rejected" {
  command = plan
  variables {
    instances = {
      "dev" = {
        instance_type  = "t3.micro"
        volume_size_gb = 20
        fqdn           = "dev.test.invalid"
        key_name       = "dev"
        policy_group   = "canary"
      }
    }
  }
  expect_failures = [var.instances]
}

# --- SSM parameter names --------------------------------------------------
# The IAM grant concatenates these onto ":parameter". A missing leading slash
# yields a syntactically valid ARN that matches nothing, and the VM fails at
# first boot with an AccessDenied on a name that looks right in the console.
# A bare "/" passes startswith() and fails the same way, which is why the check
# is a regex.

run "cinc_parameter_without_leading_slash_is_rejected" {
  command = plan
  variables { cinc_ssm_parameter_name = "developer-vms/cinc/validator" }
  expect_failures = [var.cinc_ssm_parameter_name]
}

run "cinc_parameter_of_bare_slash_is_rejected" {
  command = plan
  variables { cinc_ssm_parameter_name = "/" }
  expect_failures = [var.cinc_ssm_parameter_name]
}

run "loki_parameter_of_bare_slash_is_rejected" {
  command = plan
  variables { loki_ssm_parameter_name = "/" }
  expect_failures = [var.loki_ssm_parameter_name]
}

run "minimal_valid_parameter_names_plan" {
  command = plan
  variables {
    cinc_ssm_parameter_name = "/c"
    loki_ssm_parameter_name = "/l"
  }
}

# --- log_shipping and loki_ssm_parameter_name are one decision ---------------
#
# The cross-check lives in terraform_data.assert_log_shipping_inputs (iam.tf),
# not in a variable validation: cross-variable references there need Terraform
# 1.9 and this module's floor is 1.5. Only the two runs that need no instance
# live here — this file's fixture has instances = {}, so nothing about the
# bootstrap policy is evaluated in it. The on-without-parameter case is in
# hardening.tftest.hcl for exactly that reason.

run "shipping_off_without_a_parameter_plans" {
  command = plan
  variables {
    log_shipping            = false
    loki_ssm_parameter_name = null
  }
}

run "shipping_off_with_a_parameter_is_rejected" {
  command = plan
  variables {
    log_shipping            = false
    loki_ssm_parameter_name = "/test/loki-token"
  }
  expect_failures = [terraform_data.assert_log_shipping_inputs]
}
