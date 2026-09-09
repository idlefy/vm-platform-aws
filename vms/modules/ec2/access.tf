# Resolves each VM's `aws_access` bundle names into concrete policy ARNs, and
# fails the plan on an unknown bundle name. Without the guard, Terraform would
# happily build an identity role with no permissions and the mistake would
# surface much later as an opaque AccessDenied on the VM.

locals {
  # This module is instantiated once per region, so var.instances is already
  # narrowed to one region's VMs.
  vm_bundle_names = { for name, cfg in var.instances : name => cfg.aws_access }

  unknown_bundles = distinct(flatten([
    for _, names in local.vm_bundle_names : [
      for b in names : b if !contains(keys(var.access_bundles), b)
    ]
  ]))

  # The `if contains(...)` guard must stay: locals are evaluated before the
  # precondition below fires, and var.access_bundles[b] on a missing key is a
  # hard error with a far worse message than ours.
  vm_policy_arns = {
    for name, names in local.vm_bundle_names : name => distinct(flatten([
      for b in names : var.access_bundles[b].policy_arns
      if contains(keys(var.access_bundles), b)
    ]))
  }

  # Flattened to a single map so aws_iam_role_policy_attachment can for_each it.
  vm_policy_attachments = {
    for pair in flatten([
      for name, arns in local.vm_policy_arns : [
        for arn in arns : { key = "${name}|${arn}", vm = name, policy_arn = arn }
      ]
    ]) : pair.key => pair
  }

  # The Allow half of each VM's permissions boundary: only the namespaces its own
  # bundles declared. Anything else is denied by omission, which is the whole
  # point — an unanticipated grant in someone else's policy is blocked without
  # anyone having had to predict it.
  #
  # sts:GetCallerIdentity is prepended unconditionally so the list is never empty:
  # an IAM statement with Action = [] is a MalformedPolicyDocument, and a VM with
  # aws_access = [] must still produce a valid boundary. It is not a grant — that
  # call requires no permission and cannot be denied by policy either — so a VM
  # with no bundles still has a ceiling of nothing.
  vm_allowed_actions = {
    for name, names in local.vm_bundle_names : name => distinct(concat(
      ["sts:GetCallerIdentity"],
      flatten([
        for b in names : var.access_bundles[b].allowed_actions
        if contains(keys(var.access_bundles), b)
      ])
    ))
  }
}

resource "terraform_data" "validate_bundles" {
  input = local.unknown_bundles

  lifecycle {
    precondition {
      condition     = length(local.unknown_bundles) == 0
      error_message = "Unknown bundle name(s) in instances[*].aws_access: ${join(", ", local.unknown_bundles)}. Valid names: ${join(", ", keys(var.access_bundles))}"
    }
  }
}

# How the VM learns which role to assume. Reuses the SSM channel the VM already
# depends on for bootstrap secrets, so no new Terraform-to-CINC integration.
#
# Type String, not SecureString: an ARN and a VM name, no secrets. That keeps
# kms:Decrypt off the bootstrap role.
#
# No region in the path — Parameter Store is already regional.
resource "aws_ssm_parameter" "access" {
  for_each = var.instances

  region = var.aws_region
  name   = "/developer-vms/access/${each.key}"
  type   = "String"

  # `region` is carried for diagnostics only. The broker takes its region from
  # /etc/dev-vm/aws-access.env, because it needs a region before it can read
  # this parameter at all.
  value = jsonencode({
    identity_role_arn = aws_iam_role.identity[each.key].arn
    session_name      = each.key
    region            = var.aws_region
  })

  tags = merge(local.default_tags, { Name = "access-${each.key}" })
}
