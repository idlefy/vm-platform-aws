data "aws_caller_identity" "current" {}

# Two roles per VM.
#
#   dev-vm-boot-<vm>-<region>  attached to the instance; reads the three bootstrap
#                              secrets and may assume this VM's identity role.
#                              Reachable only by root — imds.rb blocks IMDS for
#                              every other uid.
#
#   dev-vm-id-<vm>-<region>    the developer-facing identity. Carries the policies
#                              its bundles declare, capped by a permissions
#                              boundary. Never attached to an instance.
#
# The prefixes are deliberately disjoint: phase B hands resource owners a grant
# matching dev-vm-id-*, which must never select a bootstrap role.
#
# Note the dependency shape: aws_iam_role.identity's trust policy names the
# bootstrap ROLE, while the bootstrap role's inline POLICY names the identity
# role. Keeping the bootstrap policy in its own resource is what makes this
# acyclic (bootstrap role -> identity role -> bootstrap policy).

resource "aws_iam_role" "bootstrap" {
  for_each = var.instances

  name = "dev-vm-boot-${each.key}-${var.aws_region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.default_tags, { Name = "dev-vm-boot-${each.key}" })
}

# Cross-variable checks that a `validation` block cannot express on this
# module's Terraform 1.5 floor (cross-object references there need 1.9). The
# shape is the one tenant-skeleton/vms/main.tf uses for its fleet guards: a
# terraform_data with a precondition, so the plan stops with a message that
# names the fix.
#
# Both directions are wrong, for different reasons. Shipping on with no
# parameter: the VM converges, dev-vm-loki-token has nothing to fetch, Alloy
# runs with no token and ships nothing while the unit is green. Shipping off
# with a parameter: the recipe tears Alloy down but the IAM grant stays, so the
# tenant believes the token is unreachable from the VM when it is not.
resource "terraform_data" "assert_log_shipping_inputs" {
  input = { log_shipping = var.log_shipping, loki_ssm_parameter_name = var.loki_ssm_parameter_name }

  lifecycle {
    precondition {
      condition     = !(var.log_shipping && var.loki_ssm_parameter_name == null)
      error_message = "log_shipping is true but loki_ssm_parameter_name is unset; the VM would converge and ship nothing. Set the parameter name, or set log_shipping = false."
    }

    precondition {
      condition     = !(!var.log_shipping && var.loki_ssm_parameter_name != null)
      error_message = "log_shipping is false but loki_ssm_parameter_name is set; pick one — the IAM grant and the recipe would disagree. Set loki_ssm_parameter_name = null, or set log_shipping = true."
    }
  }
}

# "${null}" inside a template is an HCL error, not an empty string, so the ARN
# is built only when there is a name to build it from. compact() below then
# removes the empty entry, so with shipping off the grant disappears entirely
# rather than degrading to a ":parameter" ARN that matches nothing.
locals {
  loki_parameter_arn = var.loki_ssm_parameter_name == null ? "" : "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.loki_ssm_parameter_name}"
}

resource "aws_iam_role_policy" "bootstrap" {
  for_each = var.instances

  name = "bootstrap"
  role = aws_iam_role.bootstrap[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadBootstrapSecretsAndOwnAccessConfig"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = compact([
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.cinc_ssm_parameter_name}",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/developer-vms/access/${each.key}",
          var.log_shipping ? local.loki_parameter_arn : "",
        ])
      },
      {
        Sid      = "AssumeOwnIdentityRole"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:SetSourceIdentity"]
        Resource = [aws_iam_role.identity[each.key].arn]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "bootstrap" {
  for_each = var.instances

  name = "dev-vm-boot-${each.key}-${var.aws_region}"
  role = aws_iam_role.bootstrap[each.key].name

  tags = local.default_tags
}

# Caps each identity role regardless of what its bundle policies contain. A
# boundary GRANTS NOTHING — effective permissions are the intersection of the
# role's attached policies and this document — so the role still has exactly the
# authority its bundles give it, and none if it has no bundles.
#
# One boundary per VM, not one per region: a shared ceiling would be the union of
# every bundle in the catalog, so it would loosen as the catalog grows and would
# no longer describe what this VM was actually granted.
#
# Two statements, doing different jobs:
#
#   Allow — only the namespaces this VM's own bundles declared in
#       allowed_actions. This is the layer that handles what we did not think of:
#       a bundle policy written by another team may grant more than its
#       description claims, and anything outside its declared namespaces is
#       denied by omission with nobody having had to predict it. A deny list
#       structurally cannot do that, which is why this is not `Action = "*"`.
#       (It was, in an earlier draft. The deny list below then had to anticipate
#       every escalation path, and two were missed and found only in review.)
#
#   Deny — the fixed escalation list, and NOT a legacy layer. Three reasons it
#       stays, in order of how much they matter:
#
#       1. Inside a service a bundle legitimately declares, the Allow list is
#          silent. A bundle declaring allowed_actions = ["ec2:*"] raises the
#          ceiling to all of EC2, and the deny list is then the ONLY control.
#          That is why the list below is long and why declaring ec2 or ssm is a
#          security review rather than a config change.
#       2. A resource-based policy naming the assumed-role SESSION ARN escapes an
#          implicit deny — permissions granted directly to a session are not
#          limited by a boundary's omission, whereas a grant to the ROLE ARN is.
#          The session ARN here is fully predictable
#          (assumed-role/dev-vm-id-<vm>-<region>/<vm>), which makes that case
#          reachable rather than theoretical.
#       3. An explicit Deny beats every allow anywhere, so it also catches a
#          careless `allowed_actions = ["iam:*"]` that slipped through review.
#
#       An earlier draft justified this layer by claiming an Allow omission does
#       not cap resource-based policies at all. That is wrong for the role ARN;
#       do not restore it.
#
# Every entry in the deny list is a path from "developer holds identity-role
# credentials" to either root on the VM or the three fleet-scoped bootstrap
# secrets. They are not stylistic preferences; removing one re-opens a specific
# attack.
#
#   iam:*, organizations:*
#       Mint or re-permission roles. Also blocks creating a role whose name
#       matches the dev-vm-id-* prefix phase B hands to resource owners.
#
#   sts:AssumeRole
#       Phase A has no chaining at all, so this also stops pivoting into another
#       VM's identity role. Phase B narrows it to role/dev-vm-*.
#
#   ssm:GetParameter*
#       Wildcard, not an enumeration. It must cover GetParameterHistory, which
#       returns each historical Value and honours --with-decryption — i.e. it
#       reads the CINC validator key just as well as GetParameter does. A bundle
#       carrying a routine "ssm:Get*" for app config would otherwise defeat the
#       whole control.
#
#   ec2-instance-connect:*, ec2:GetPasswordData
#       ssh.rb:46 sets AuthorizedKeysCommand to the EIC helper over %u, and
#       ssh.rb:22 gives the admin user NOPASSWD:ALL. So SendSSHPublicKey for
#       --instance-os-user admin, then ssh, is root on this VM in two commands —
#       with no PassRole and nothing for iam:* to catch.
#
#   ec2:RunInstances
#       Launch an instance carrying a bootstrap instance profile and read both
#       secrets as root on a machine the developer fully controls.
#
#   ec2:ModifyInstanceAttribute
#       Cheaper than RunInstances and needs no PassRole: rewrite the user data of
#       an instance that ALREADY carries a bootstrap profile, then stop/start it.
#       cloud-init's once-per-instance semaphore does not save us — a
#       #cloud-boothook payload runs on every boot.
#
#   ec2:CreateReplaceRootVolumeTask
#       ModifyInstanceAttribute's objective by another route: replace the root
#       volume of an instance that already carries a bootstrap profile with an
#       image the developer controls, and they are root on a machine holding the
#       bootstrap role. No PassRole here either.
#
#   ec2:StopInstances, ec2:DetachVolume, ec2:AttachVolume
#       The short way to the same disk the snapshot entries below protect. A root
#       volume can be detached once its instance is stopped, so: stop the victim,
#       detach its root volume, attach it to a machine the developer already
#       controls, mount it, read both secrets. Three calls, no snapshot, no
#       PassRole — which is why denying the snapshot chain alone was not enough.
#       All three are needed, not just StopInstances: an instance that is already
#       stopped skips the first step entirely.
#
#   ec2:AssociateIamInstanceProfile, ec2:ReplaceIamInstanceProfileAssociation
#       Move a bootstrap profile onto an instance the developer controls. These
#       do require iam:PassRole, so iam:* already catches them; listed so the set
#       is complete and nobody prunes it while narrowing iam:* later.
#
#   ec2:CreateImage, ec2:ModifyImageAttribute
#       The snapshot path around every snapshot action: CreateImage needs only
#       ec2:CreateImage, and sharing the AMI to the developer's own account needs
#       only ModifyImageAttribute. Denying CreateSnapshot alone was the same
#       enumeration mistake as the earlier ssm:GetParameter one.
#
#   ec2:CreateSnapshot, ec2:CreateSnapshots, ec2:CopySnapshot,
#   ec2:ModifySnapshotAttribute, ec2:CreateVolume
#       Snapshot or copy the root volume, share it, mount it elsewhere, read
#       /etc/cinc/client.pem and /etc/alloy/loki-token directly off disk.
#
#   ssm:StartSession, ssm:SendCommand, ssm:StartAutomationExecution,
#   ssm:CreateAssociation, ssm:UpdateAssociation
#       Remote command execution as root on any managed instance. The two
#       Association actions do it via AWS-RunShellScript and are not covered by
#       SendCommand. Not exploitable today — the bootstrap role carries no
#       AmazonSSMManagedInstanceCore, so the agent is unregistered — but that is
#       a property of a policy that can change, not of this boundary.
#
#   ssm:PutParameter, ssm:DeleteParameter*
#       Integrity, not confidentiality: overwriting the validator-key parameter
#       does not reveal it but breaks enrolment for every VM created afterwards.
#       A second, distinct reason this deny matters: the same action also
#       reaches the Loki token parameter, and overwriting that one does not
#       break enrolment at all — it silently stops log shipping fleet-wide,
#       since nothing re-fetches the old value and nothing alerts on a write.
#
# A boundary constrains permissions but not a role's trust policy. That is fine
# here: the identity role trusts only its own bootstrap role.
#
# Editing a VM's aws_access rewrites this document, and IAM keeps at most five
# versions of a managed policy. After the fifth edit, apply may fail with
# LimitExceeded; delete the oldest non-default version and re-apply. See the
# spec's Error handling table.
resource "aws_iam_policy" "identity_boundary" {
  for_each = var.instances

  name        = "dev-vm-id-boundary-${each.key}-${var.aws_region}"
  description = "Upper bound on ${each.key}'s identity role: only the namespaces its bundles declared, minus the escalation deny list."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowOnlyDeclaredNamespaces"
        Effect   = "Allow"
        Action   = local.vm_allowed_actions[each.key]
        Resource = "*"
      },
      {
        Sid    = "DenyEscalationAndBootstrapSecrets"
        Effect = "Deny"
        Action = [
          "iam:*",
          "organizations:*",
          "sts:AssumeRole",
          "ssm:GetParameter*",
          "ssm:StartSession",
          "ssm:SendCommand",
          "ssm:StartAutomationExecution",
          "ssm:CreateAssociation",
          "ssm:UpdateAssociation",
          "ssm:PutParameter",
          "ssm:DeleteParameter*",
          "ec2-instance-connect:*",
          "ec2:GetPasswordData",
          # Launch paths, enumerated ACROSS namespaces: every API that can
          # start compute carrying an instance profile, not only the one named
          # RunInstances. All of them need iam:PassRole, which iam:* denies
          # today — but the phase-B plan narrows iam:* to role/dev-vm-*, and
          # then this enumeration is the control. The autoscaling, batch, and
          # imagebuilder families each live in their own namespaces, which ec2:*
          # entries can never cover once a bundle declares those namespaces.
          # Any future launch API belongs here. (Fifth instance of the
          # multi-call-path omission CLAUDE.md documents; enumerated 2026-08-25.)
          # Every Create in this list carries its Update/Modify sibling, because
          # modifying an existing resource to point at a bootstrap-profile launch
          # template is the same escalation without iam:PassRole
          # (CreateLaunchTemplateVersion + $Latest-tracking ASGs being the
          # canonical no-PassRole example).
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
          "ec2:ModifyInstanceAttribute",
          "ec2:AssociateIamInstanceProfile",
          "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:CreateImage",
          "ec2:ModifyImageAttribute",
          "ec2:CreateSnapshot",
          "ec2:CreateSnapshots",
          "ec2:CopySnapshot",
          "ec2:ModifySnapshotAttribute",
          "ec2:CreateVolume",
          "ec2:CreateReplaceRootVolumeTask",
          "ec2:StopInstances",
          "ec2:DetachVolume",
          "ec2:AttachVolume",
          # Routes found in the first external review (docs/design/first-external-review.md §3).
          # EBS direct APIs read and write snapshot blocks without any ec2: call —
          # the snapshot denies above do not cover them. Sixth instance of the
          # multi-call-path omission CLAUDE.md documents.
          "ebs:ListSnapshotBlocks",
          "ebs:ListChangedBlocks",
          "ebs:GetSnapshotBlock",
          "ebs:StartSnapshot",
          "ebs:PutSnapshotBlock",
          "ebs:CompleteSnapshot",
          # The fleet's egress is its audit transport: an ACL or route change
          # black-holes Loki for every VM in the subnet, and the "no logs"
          # condition cannot be alerted on over the transport that was cut.
          # Ingress stays open — a developer opening a port on their own VM is
          # the documented self-service.
          "ec2:CreateNetworkAclEntry",
          "ec2:ReplaceNetworkAclEntry",
          "ec2:DeleteNetworkAclEntry",
          "ec2:ReplaceNetworkAclAssociation",
          "ec2:CreateRoute",
          "ec2:ReplaceRoute",
          "ec2:DeleteRoute",
          "ec2:ReplaceRouteTableAssociation",
          "ec2:DisassociateRouteTable",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:ModifySecurityGroupRules",
          # Peers' availability, and the fail-closed bootstrap log (user_data.tf).
          "ec2:TerminateInstances",
          "ec2:RebootInstances",
          "ec2:GetConsoleOutput",
          "ec2:GetConsoleScreenshot",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.default_tags
}

resource "aws_iam_role" "identity" {
  for_each = var.instances

  name                 = "dev-vm-id-${each.key}-${var.aws_region}"
  permissions_boundary = aws_iam_policy.identity_boundary[each.key].arn

  # Role chaining caps sessions at one hour regardless of this value; setting it
  # explicitly documents the ceiling the broker must not exceed.
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.bootstrap[each.key].arn }
      Action    = ["sts:AssumeRole", "sts:SetSourceIdentity"]
      Condition = {
        StringEquals = { "sts:SourceIdentity" = each.key }
      }
    }]
  })

  tags = merge(local.default_tags, { Name = "dev-vm-id-${each.key}" })
}

resource "aws_iam_role_policy_attachment" "identity" {
  for_each = local.vm_policy_attachments

  role       = aws_iam_role.identity[each.value.vm].name
  policy_arn = each.value.policy_arn
}
