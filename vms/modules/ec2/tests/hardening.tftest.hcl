# Plan-time regression pins for the user_data and boundary hardening. Unlike
# validation.tftest.hcl these runs render a real instance, so the fixture
# carries one VM.

# aws_iam_role_policy.bootstrap's policy JSON includes
# aws_iam_role.identity[each.key].arn (the AssumeOwnIdentityRole statement).
# That's a Computed attribute of another resource this same plan is creating,
# so without an override it is unknown at `plan` time — not because the
# bootstrap policy is unresolved, but because jsonencode() cannot partially
# serialize an unknown input. override_during = plan supplies a stand-in
# early enough for the two log-shipping runs below to assert on the
# rendered policy string at plan time; assert_log_shipping_inputs and its
# precondition are the thing under test and do not depend on this value.
mock_provider "aws" {
  override_resource {
    target          = aws_iam_role.identity
    override_during = plan
    # Single-instance fixture: one fixed id/arn is correct only while the
    # fixture has exactly one VM; add a second override if a second instance
    # is ever added.
    values = {
      id  = "dev-vm-id-vm-eu-central-1"
      arn = "arn:aws:iam::123456789012:role/dev-vm-id-vm-eu-central-1"
    }
  }
}

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

  instances = {
    "vm" = {
      instance_type  = "t3.micro"
      volume_size_gb = 20
      fqdn           = "vm.test.invalid"
      key_name       = "dev"
    }
  }
  access_bundles = {}
}

run "user_data_fails_closed_on_imds" {
  command = plan

  assert {
    condition     = strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "curl -sf")
    error_message = "The IMDS curls must carry -f, or an HTTP error body becomes the instance name with exit 0."
  }

  assert {
    condition     = strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "could not read the Name tag")
    error_message = "A garbage or missing Name tag must abort the bootstrap with a named diagnostic, not register a garbage node."
  }

  assert {
    condition     = strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "could not read the PolicyName tag")
    error_message = "A garbage or missing PolicyName tag must abort the bootstrap with a named diagnostic."
  }

  assert {
    condition     = strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "bootstrap_failed; exit 1")
    error_message = "A FATAL validation branch must call bootstrap_failed itself before exiting — an explicit exit does not fire the ERR trap, so a bare 'exit 1' here would leave the validation key on disk."
  }

  assert {
    condition     = !strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "90-cloud-init-users.bak")
    error_message = "The bootstrap must never keep a copy of cloud-init's NOPASSWD grant: restoring it on failure hands the developer root, IMDS and the bootstrap role (first external review, C2)."
  }

  assert {
    condition = (
      strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "> /dev/console") &&
      strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "/var/log/user-data.log")
    )
    error_message = "A failed bootstrap must write its log to the serial console — with sudo gone, get-console-output is the only diagnosis path."
  }

  assert {
    condition     = !strcontains(base64decode(aws_instance.this["vm"].user_data_base64), "install -m 0440")
    error_message = "The bootstrap must never re-create the sudoers grant — a 0440 install of 90-cloud-init-users is exactly the restore this script must not do."
  }

  assert {
    condition     = length(regexall("/etc/sudoers.d", base64decode(aws_instance.this["vm"].user_data_base64))) == 1
    error_message = "The script may name /etc/sudoers.d only once, in the rm that drops cloud-init's grant — a second mention would be a re-creation path."
  }

}

run "boundary_denies_every_launch_path" {
  command = plan

  assert {
    condition = alltrue([
      for action in [
        "ec2:RunInstances",
        "ec2:CreateFleet",
        "ec2:RequestSpotInstances",
        "ec2:RequestSpotFleet",
        "ec2:RunScheduledInstances",
        "ec2:CreateLaunchTemplateVersion",
        "ec2:ModifyLaunchTemplate",
        "ec2:ModifyFleet",
        "ec2:ModifySpotFleetRequest",
        "autoscaling:CreateAutoScalingGroup",
        "autoscaling:CreateLaunchConfiguration",
        "autoscaling:UpdateAutoScalingGroup",
        "batch:CreateComputeEnvironment",
        "batch:UpdateComputeEnvironment",
        "imagebuilder:CreateInfrastructureConfiguration",
        "imagebuilder:UpdateInfrastructureConfiguration",
      ] : strcontains(aws_iam_policy.identity_boundary["vm"].policy, action)
    ])
    error_message = "The identity boundary must deny every launch-with-instance-profile action, across namespaces — not just RunInstances."
  }
}

# --- log shipping: the three runs that need a real instance ------------------
# aws_iam_role_policy.bootstrap is for_each = var.instances, so only with the
# "vm" fixture is its Resource list — and local.loki_parameter_arn — evaluated.
# That is what makes these three prove iam.tf is null-safe: a run fails on ANY
# error other than the one expect_failures names, so if the ARN template ever
# interpolated a null, "Invalid template interpolation value" from iam.tf would
# fail the run instead of the precondition.

run "shipping_on_keeps_the_loki_grant" {
  command = plan
  # log_shipping defaults to true and the file's variables block supplies the parameter name.
  assert {
    condition     = strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "parameter/test/loki-token")
    error_message = "with log_shipping on, the bootstrap policy must grant the Loki token parameter"
  }
}

run "shipping_on_without_a_parameter_is_rejected" {
  command = plan
  variables {
    log_shipping            = true
    loki_ssm_parameter_name = null
  }
  expect_failures = [terraform_data.assert_log_shipping_inputs]
}

run "shipping_off_drops_the_loki_grant" {
  command = plan
  variables {
    log_shipping            = false
    loki_ssm_parameter_name = null
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "parameter/test/loki-token")
    error_message = "With log_shipping = false the bootstrap policy must not grant the Loki parameter."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.bootstrap["vm"].policy, ":parameter\"")
    error_message = "The grant must disappear, not degrade to a bare ':parameter' ARN that matches nothing."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "parameter/test/cinc-validator")
    error_message = "The CINC validator grant must survive turning log shipping off."
  }
}

# --- idlefy_managed: three runs that need a real instance ---------------------
# The tag lives on aws_instance.this, so validation.tftest.hcl (instances = {})
# would pass every one of these vacuously. The fixture key here is "vm".

run "idlefy_tag_is_on_by_default" {
  command = plan

  assert {
    condition     = lookup(aws_instance.this["vm"].tags, "idlefy", "") == "enabled"
    error_message = "By default every instance must carry idlefy = \"enabled\" — lowercase key, that exact value; Idlefy's IAM condition matches nothing else."
  }
}

run "idlefy_managed_false_drops_the_tag" {
  command = plan
  variables {
    idlefy_managed = false
  }

  assert {
    condition     = !contains(keys(aws_instance.this["vm"].tags), "idlefy")
    error_message = "With idlefy_managed = false the idlefy key must be absent, not set to some other value."
  }
}

run "fleet_wide_tags_override_the_flag" {
  command = plan
  # idlefy_managed stays at its default (true): the point is that var.tags wins
  # over the flag, which only holds while the flag's map is merged FIRST.
  variables {
    tags = { idlefy = "disabled" }
  }

  assert {
    condition     = aws_instance.this["vm"].tags["idlefy"] == "disabled"
    error_message = "A fleet-wide tags = { idlefy = \"disabled\" } must win over idlefy_managed = true; the flag's map has to be the first argument to merge()."
  }

  assert {
    condition     = aws_instance.this["vm"].tags["ManagedBy"] == "Terraform"
    error_message = "Reordering the merge must not lose local.default_tags."
  }
}
