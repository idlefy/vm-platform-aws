# One output keyed by region, replacing the per-region blocks this file used to
# hold. Nothing in the repo consumed the old `us_east_1` / `eu_north_1` /
# `eu_central_1` names (checked before the rename), so this is a rename rather
# than a break — but it IS a rename: read a single region with
#
#   terraform output -json regions | jq '.["us-east-1"]'
#
# rather than `terraform output -json us_east_1`.
output "regions" {
  description = "EC2 outputs per region, keyed by region name."
  value = {
    for region, m in module.ec2 : region => {
      instance_ids         = m.instance_ids
      instance_private_ips = m.instance_private_ips
      instance_elastic_ips = m.instance_elastic_ips
      instance_fqdns       = m.instance_fqdns
      security_group_id    = m.security_group_id
      ssh_key_names        = m.ssh_key_names
      identity_role_arns   = m.identity_role_arns
    }
  }
}

# Flat VM-name -> instance-id across all regions. VM names are unique fleet-wide
# (they become IAM role names and CINC node names), so flattening cannot collide,
# and it saves every caller from having to know which region a VM is in — both
# `make ssh` and the node-deletion flow start from a name.
output "instance_ids" {
  description = "Instance id by VM name, across every region."
  value       = merge([for m in module.ec2 : m.instance_ids]...)
}

# The region set this tenant configures.
#
# One consumer today: the skeleton's smoke test asserts it is non-empty, because
# with no regions configured every module-scoped validation evaluates over an
# empty instances map and checks nothing.
#
# scripts/preflight.sh deliberately does NOT read this. It gets the same list
# from `terraform console` on local.regions, which needs a resolved .terraform/
# but no state; `terraform output` would need backend state, which preflight is
# expected to run without. Do not "simplify" one into the other.
output "configured_regions" {
  description = "Names of the AWS regions this tenant configures, from config.tf."
  value       = keys(local.regions)
}
