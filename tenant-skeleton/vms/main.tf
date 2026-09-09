terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      # v6 or newer is required, not merely preferred: the single-provider
      # arrangement below depends on the per-resource `region` argument that v6
      # introduced. On v5 every resource would silently land in
      # local.provider_region.
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# --- The published platform this tenant runs ---
#
# `make prepare` resolves both placeholders: it takes the tag from the operator,
# resolves it with `git ls-remote`, and writes the tag and the commit here and
# into every module `source` below.
#
# This local is legible, not load-bearing. A module `source` is a literal —
# Terraform does not interpolate variables into it — so these values cannot feed
# the sources, and each source carries its own copy of the SHA. `make pin-check`
# is what keeps the three in agreement; nothing in Terraform does.
locals {
  platform_pin = {
    tag = "__PLATFORM_TAG__"
    sha = "__PLATFORM_SHA__"
  }
}

# --- Provider ---
#
# One provider, not one alias per region. Terraform cannot generate provider
# blocks and `providers = {}` in a module call cannot be dynamic, so aliases would
# force a hand-written provider + module + output trio per region — which is what
# this file used to be, and why adding a region meant editing five files. Instead
# each resource in modules/ec2 sets its own `region`, and the module below is a
# single `for_each` over local.regions.
#
# See local.provider_region in config.tf for what this region does and does not
# decide. `default_tags` is deliberately absent: modules/ec2 already applies
# Environment/Region/ManagedBy to every taggable resource through
# local.default_tags, so a provider-level block would only duplicate them — and it
# could not vary Region per region with one provider anyway.
provider "aws" {
  region  = local.provider_region
  profile = var.aws_profile

  skip_credentials_validation = true
  skip_metadata_api_check     = true
}

# --- EC2, once per region ---

module "ec2" {
  source   = "git::https://github.com/idlefy/vm-platform-aws.git//vms/modules/ec2?ref=__PLATFORM_SHA__" # __PLATFORM_TAG__
  for_each = local.regions

  environment = local.environment
  aws_region  = each.key

  network_config = each.value.network_config
  default_az     = each.value.default_az

  # `lookup(..., {})`, not `var.instances[each.key]`: a region with no VMs is a
  # normal state, and requiring a key here would mean every new region had to be
  # added to instances.auto.tfvars before it would plan. The typo that leniency
  # would otherwise hide — a region key in instances.auto.tfvars that matches no
  # configured region, silently ignored — is caught by
  # terraform_data.assert_no_orphan_region_keys below.
  instances     = lookup(var.instances, each.key, {})
  ssh_key_pairs = lookup(var.ssh_key_pairs, each.key, {})

  security_group_rules    = local.shared_security_group_rules
  route53_zone_id         = var.route53_zone_id
  cinc_ssm_parameter_name = var.cinc_ssm_parameter_name
  loki_ssm_parameter_name = var.loki_ssm_parameter_name
  log_shipping            = var.log_shipping
  idlefy_managed          = var.idlefy_managed
  cinc_server_url         = var.cinc_server_url
  access_bundles          = var.access_bundles

  ami_name_pattern = var.ami_name_pattern
  ami_owners       = var.ami_owners
}

# --- Fleet-wide guards ---
#
# The computation is published; the assertions are not, and that split is forced
# rather than chosen. `expect_failures` cannot name an object inside a child
# module, and a test run block cannot point at a remote source — so a
# precondition living in the module would be unassertable by the one test this
# repository runs, and a guard wired so that it can never fire is precisely what
# these guards exist to catch.
#
# Both maps go in. The orphan check reads instances AND ssh_key_pairs: a
# developer's key added under a region config.tf does not configure is caught
# only by the second half, and omitting it here silently halves the guard.
module "fleet_guards" {
  source = "git::https://github.com/idlefy/vm-platform-aws.git//vms/modules/fleet-guards?ref=__PLATFORM_SHA__" # __PLATFORM_TAG__

  instances     = var.instances
  ssh_key_pairs = var.ssh_key_pairs
  regions       = keys(local.regions)
}

# A region key that matches nothing in local.regions builds no resources and
# reports no error: the VM listed under it simply never exists. That is the one
# failure mode the single-provider for_each arrangement introduced.
resource "terraform_data" "assert_no_orphan_region_keys" {
  input = module.fleet_guards.orphan_region_keys

  lifecycle {
    precondition {
      condition     = length(module.fleet_guards.orphan_region_keys) == 0
      error_message = "instances/ssh_key_pairs name region(s) that config.tf does not configure: ${join(", ", module.fleet_guards.orphan_region_keys)}. Configured: ${join(", ", keys(local.regions))}. Add the region with `cd cinc && make add-region REGION=<region>`, or fix the key."
    }
  }
}

# VM names must be unique across the whole fleet, not merely within a region.
#
# What breaks is not Terraform. IAM role names carry the region, so they do not
# collide, and each VM gets its own instance — the plan looks entirely
# reasonable. The collision is downstream: user_data writes
# `node_name "$INSTANCE_NAME"` from the unqualified Name tag, so two same-named
# VMs register as ONE CINC node and overwrite each other's attributes every 30
# minutes. `make node-delete NODE=<name>` cannot say which one it means, and
# outputs.instance_ids merges the regional maps, so one of the two silently
# disappears from every consumer that resolves a VM by name.
resource "terraform_data" "assert_no_duplicate_vm_names" {
  input = module.fleet_guards.duplicate_vm_names

  lifecycle {
    precondition {
      condition     = length(module.fleet_guards.duplicate_vm_names) == 0
      error_message = "VM names must be unique across every region, and these appear more than once: ${join(", ", module.fleet_guards.duplicate_vm_names)}. The name becomes the CINC node_name, which is not region-qualified, so both VMs would share one node object and overwrite each other's attributes on every converge. Rename one of them."
    }
  }
}

# The rename, for tenants that predate the split.
#
# Root-to-root: module.fleet_guards holds no resource, so there is nothing
# inside it to move to. Writing a `to` that names something in the module while
# the root resource still exists produces "Error: Moved object still exists" and
# no plan at all — reproduced on Terraform 1.15.8.
#
# In a fresh tenant these are harmless no-ops (`Plan: 2 to add`). They can be
# pruned once every tenant has migrated; nothing forces it.
moved {
  from = terraform_data.validate_unique_vm_names
  to   = terraform_data.assert_no_duplicate_vm_names
}

moved {
  from = terraform_data.validate_region_keys
  to   = terraform_data.assert_no_orphan_region_keys
}
