# The one test a tenant runs.
#
# It is not a test of the platform — the modules are gated upstream, in their own
# directories, where expect_failures can name their internals. This file gates
# the WIRING: that this root passes the right things to the right modules and
# that both fleet guards can still fire. A guard wired so that it can never fire
# is the failure the guards exist to prevent, and it is invisible in a plan.
#
# Requires Terraform >= 1.7 for mock_provider. plan and apply work on the root's
# declared >= 1.5.0 floor; only this file needs the newer one.
#
# Every variable is set explicitly, on purpose. `terraform test` otherwise falls
# back to this root's *.auto.tfvars — which in a live tenant describe the real
# fleet, so a variable added to the skeleton and forgotten here would make the
# smoke test plan against production data while looking like a fixture.

mock_provider "aws" {}

variables {
  aws_profile             = "test-profile"
  route53_zone_id         = "Z00000000000000000TEST"
  cinc_ssm_parameter_name = "/test/cinc-validator"
  log_shipping            = true
  loki_ssm_parameter_name = "/test/loki-token"
  idlefy_managed          = true
  cinc_server_url         = "https://cinc.test.invalid/organizations/test"

  instances      = {}
  ssh_key_pairs  = {}
  access_bundles = {}

  # Defaulted in variables.tf, and set anyway. The rule at the top of this file
  # is "every variable this root declares", not "every variable without a
  # default": a tenant whose instances.auto.tfvars overrides one would otherwise
  # have that override silently pulled into the fixture.
  ami_name_pattern = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
  ami_owners       = ["099720109477"]
}

# --- the root is wired to something -----------------------------------------

run "an_empty_fleet_plans" {
  command = plan

  assert {
    condition     = length(output.configured_regions) > 0
    error_message = "config.tf configures no regions. Every module-scoped validation then evaluates over an empty instances map and checks nothing — measured: an access_bundles entry containing a literal \"*\" plans clean in that state."
  }
}

# --- both guards can fire ----------------------------------------------------
#
# Two region keys no tenant configures, carrying one VM name twice. That trips
# BOTH guards, and both are listed: expect_failures requires each named object
# to report an error, so this cannot pass on the orphan guard alone.
#
# Using invented region keys is what keeps this file portable. A fixture naming
# real regions fails in the next tenant whose config.tf differs, and a smoke
# test that fails on correct configuration gets deleted rather than fixed.

run "a_duplicate_vm_name_and_an_unconfigured_region_both_stop_the_plan" {
  command = plan
  variables {
    instances = {
      "smoke-region-1" = {
        "dup" = { instance_type = "t3.micro", volume_size_gb = 20, fqdn = "a.test.invalid", key_name = "k" }
      }
      "smoke-region-2" = {
        "dup" = { instance_type = "t3.micro", volume_size_gb = 20, fqdn = "b.test.invalid", key_name = "k" }
      }
    }
  }
  expect_failures = [
    terraform_data.assert_no_duplicate_vm_names,
    terraform_data.assert_no_orphan_region_keys,
  ]
}

# --- both routes into the orphan guard ---------------------------------------
# The ssh_key_pairs route is the half with no second line of defence: an orphan
# in `instances` eventually shows up as a VM that never appeared, whereas a key
# under an unconfigured region simply never reaches anyone, silently.

run "an_unconfigured_region_in_instances_stops_the_plan" {
  command = plan
  variables {
    instances = {
      "smoke-region-1" = {
        "solo" = { instance_type = "t3.micro", volume_size_gb = 20, fqdn = "s.test.invalid", key_name = "k" }
      }
    }
  }
  expect_failures = [terraform_data.assert_no_orphan_region_keys]
}

run "an_unconfigured_region_in_ssh_key_pairs_alone_stops_the_plan" {
  command = plan
  variables {
    ssh_key_pairs = {
      "smoke-region-1" = { "k" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST dev@test" }
    }
  }
  expect_failures = [terraform_data.assert_no_orphan_region_keys]
}

# --- shipping off is a valid tenant ------------------------------------------
# The module rejects `log_shipping = false` with a parameter name still set;
# this proves the root passes both through, so a tenant can actually turn it
# off. If the wiring dropped log_shipping, the module default (true) would meet
# a null parameter and the plan would fail on the module's guard.

run "a_tenant_with_shipping_off_plans" {
  command = plan
  variables {
    log_shipping            = false
    loki_ssm_parameter_name = null
  }
}
