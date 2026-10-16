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
  loki_ssm_parameter_name = "/test/loki-token"
  policy_bucket           = "tenant-policies"
  policy_bucket_owner     = "123456789012"
  policy_bucket_region    = "eu-central-1"
  policy_signers          = ["ops namespaces=\"dev-vm-policy-staging,dev-vm-policy-production\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMkEu+CUWYGvccB0PoBw6SX1d6kJOSy2vALB7cAntO+E"]
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
    condition     = strcontains(local.user_data_script, "curl -sf")
    error_message = "The IMDS curls must carry -f, or an HTTP error body becomes the instance name with exit 0."
  }

  assert {
    condition     = strcontains(local.user_data_script, "could not read the Name tag")
    error_message = "A garbage or missing Name tag must abort the bootstrap with a named diagnostic, not register a garbage node."
  }

  assert {
    condition     = strcontains(local.user_data_script, "could not read the PolicyName tag")
    error_message = "A garbage or missing PolicyName tag must abort the bootstrap with a named diagnostic."
  }

  assert {
    condition     = strcontains(local.user_data_script, "bootstrap_failed; exit 1")
    error_message = "A FATAL validation branch must call bootstrap_failed itself before exiting — an explicit exit does not fire the ERR trap, so a bare 'exit 1' here would skip the console diagnosis."
  }

  assert {
    condition     = !strcontains(local.user_data_script, "90-cloud-init-users.bak")
    error_message = "The bootstrap must never keep a copy of cloud-init's NOPASSWD grant: restoring it on failure hands the developer root, IMDS and the bootstrap role (first external review, C2)."
  }

  assert {
    condition = (
      strcontains(local.user_data_script, "> /dev/console") &&
      strcontains(local.user_data_script, "/var/log/user-data.log")
    )
    error_message = "A failed bootstrap must write its log to the serial console — with sudo gone, get-console-output is the only diagnosis path."
  }

  assert {
    condition     = !strcontains(local.user_data_script, "install -m 0440")
    error_message = "The bootstrap must never re-create the sudoers grant — a 0440 install of 90-cloud-init-users is exactly the restore this script must not do."
  }

  assert {
    condition     = length(regexall("/etc/sudoers.d", local.user_data_script)) == 1
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

run "bootstrap_user_data_output_is_the_rendered_script" {
  command = plan
  assert {
    condition     = output.bootstrap_user_data == local.user_data_script
    error_message = "bootstrap_user_data must be exactly what instances boot with; make ami appends to it."
  }
  assert {
    condition     = startswith(output.bootstrap_user_data, "#!/bin/bash\n")
    error_message = "bootstrap_user_data must be the plain script, not the gzipped form."
  }
}

run "bootstrap_is_idempotent_on_a_prebuilt_image" {
  command = plan
  assert {
    condition     = strcontains(local.user_data_script, "dpkg-query -W -f='$${db:Status-Abbrev} $${Version}' cinc")
    error_message = "the CINC download must be skipped when the pinned version is installed (prebuilt image)."
  }
  assert {
    condition     = strcontains(local.user_data_script, "iptables -C OUTPUT \"$@\" 2>/dev/null || iptables -A OUTPUT \"$@\"") && !strcontains(local.user_data_script, "iptables -A OUTPUT -d 169.254.169.254")
    error_message = "every IMDS iptables -A needs an iptables -C guard: a prebuilt image restores rules.v4 before the bootstrap runs."
  }
}

run "boundary_denies_asset_routes_found_in_review" {
  command = plan

  # Anchored on the Deny statement's Action list, not the whole policy JSON
  # string — a Sid, a description, or an unrelated Allow entry could otherwise
  # make strcontains() pass without the action actually being denied.
  assert {
    condition = alltrue([
      for action in [
        # snapshot content without any ec2: call (EBS direct API)
        "ebs:ListSnapshotBlocks",
        "ebs:ListChangedBlocks",
        "ebs:GetSnapshotBlock",
        "ebs:StartSnapshot",
        "ebs:PutSnapshotBlock",
        "ebs:CompleteSnapshot",
        # the fleet's shared network path (Loki egress, and the one shared SG)
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
        "ec2:RevokeSecurityGroupIngress",
        "ec2:ModifySecurityGroupRules",
        "ec2:ModifyNetworkInterfaceAttribute",
        # other instances' availability
        "ec2:TerminateInstances",
        "ec2:RebootInstances",
        # another VM's fail-closed bootstrap log
        "ec2:GetConsoleOutput",
        "ec2:GetConsoleScreenshot",
        # IGW/route one-call blackholes, denied ahead of the topology that
        # would make them live
        "ec2:DetachInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:AssociateRouteTable",
        "ec2:DeleteNatGateway",
        ] : contains(
        [
          for statement in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
          statement.Action if statement.Effect == "Deny"
        ][0],
        action
      )
    ])
    error_message = "The identity boundary's Deny statement must cover the EBS direct-read, fleet-network, termination and console-output routes (first external review, H1/H2)."
  }

  # Glob-matched, like the sibling-route test below: the image routes are
  # partly wildcard families, so contains() on the literal list would miss them.
  assert {
    condition = alltrue([
      for action in [
        "ec2:RegisterImage", "ec2:CopyImage", "ec2:CreateImage", "ec2:ImportImage",
        "ec2:CreateRestoreImageTask", "ec2:CreateStoreImageTask", "ec2:ExportImage",
        "ec2:ModifyImageAttribute", "ec2:DeregisterImage", "ec2:EnableImage",
        "ec2:ImportSnapshot", "ec2:CopySnapshot", "ec2:ModifySnapshotAttribute", "ec2:DeleteSnapshot",
        "ec2:DisableImage", "ec2:EnableImageDeprecation", "ec2:DisableImageDeprecation",
        "ec2:DisableImageBlockPublicAccess", "ec2:DisableImageDeregistrationProtection",
        "ec2:RestoreImageFromRecycleBin", "ec2:RestoreSnapshotFromRecycleBin",
        # Image Builder registers AMIs in this account through its own role, so
        # these need no iam:PassRole once an infrastructure configuration exists.
        "imagebuilder:CreateImage", "imagebuilder:CreateImageRecipe", "imagebuilder:CreateImagePipeline",
        "imagebuilder:StartImagePipelineExecution", "imagebuilder:CreateDistributionConfiguration",
        "imagebuilder:UpdateDistributionConfiguration", "imagebuilder:ImportVmImage",
        "imagebuilder:ImportDiskImage", "imagebuilder:CreateLifecyclePolicy",
        "imagebuilder:StartResourceStateUpdate", "imagebuilder:PutImagePolicy",
        ] : anytrue([
          for st in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
          st.Effect == "Deny" && anytrue([
            for p in flatten([st.Action]) : can(regex("^${replace(p, "*", ".*")}$", action))
          ])
      ])
    ])
    error_message = "With ami_owners = [\"self\"], anyone who can register or copy an image under the name pattern chooses what the next VM boots, anyone who can store, export or share one reads it, and anyone who can disable, deprecate or hide one rolls the fleet back. Every image route must be denied (AGENTS.md trap 1)."
  }

  # Resolving the newest image is a read the data source needs.
  assert {
    condition = !anytrue([
      for st in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
      st.Effect == "Deny" && anytrue([
        for p in flatten([st.Action]) : can(regex("^${replace(p, "*", ".*")}$", "ec2:DescribeImages"))
      ])
    ])
    error_message = "A deny wildcard matches ec2:DescribeImages, which the AMI lookup needs."
  }

  assert {
    condition = !contains(
      [
        for statement in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
        statement.Action if statement.Effect == "Deny"
      ][0],
      "ec2:AuthorizeSecurityGroupIngress"
    )
    error_message = "Security-group ingress authorize is a reviewed exception (the boundary is Resource=\"*\" and cannot scope it per VM); do not deny it here."
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
    condition     = strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "arn:aws:s3:::tenant-policies/dev-vm-policies/dev-vm/*")
    error_message = "The policy read grant must survive turning log shipping off."
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

# --- serverless policy delivery ------------------------------------------------
# docs/design/serverless-policy-delivery.md. user_data is shipped gzipped, so
# these assert on local.user_data_script, the plain form main.tf compresses.

run "user_data_bootstraps_from_the_bucket" {
  command = plan

  assert {
    condition     = !strcontains(local.user_data_script, "validation.pem") && !strcontains(local.user_data_script, "chef_server_url")
    error_message = "There is no CINC server: the bootstrap must not fetch a validator key or write a server-mode client.rb."
  }

  assert {
    condition = alltrue([for line in [
      "POLICY_BUCKET=tenant-policies",
      "POLICY_BUCKET_OWNER=123456789012",
      "POLICY_BUCKET_REGION=eu-central-1",
      "POLICY_PREFIX=dev-vm-policies",
      "FLEET_ID=tenant-policies/dev-vm-policies",
      "POLICY_NAME=$POLICY_NAME",
      "POLICY_GROUP=$POLICY_GROUP",
      "NODE_NAME=$INSTANCE_NAME",
      "POLICY_MIN_SERIAL=0",
    ] : strcontains(local.user_data_script, "\n${line}\n")])
    error_message = "policy.conf must carry every key dev-vm-policy-fetch requires, and NODE_NAME must be the Name tag: alloy.rb and aws_access.rb pass node.name on as the Loki instance label and the per-VM SSM key."
  }

  assert {
    condition     = strcontains(local.user_data_script, "<<'POLICY_SIGNERS'\nops namespaces=")
    error_message = "The first trust set must be var.policy_signers, written through a quoted heredoc so nothing in it expands."
  }

  assert {
    condition     = strcontains(local.user_data_script, "DEV_VM_POLICY_STATE:-/var/lib/dev-vm/policy") && strcontains(local.user_data_script, "DEV_VM_POLICY_FETCH:-/usr/local/sbin/dev-vm-policy-fetch")
    error_message = "user_data must install dev-vm-policy-fetch and its launcher: the first converge has nothing else to deliver them."
  }

  assert {
    condition     = strcontains(local.user_data_script, "<<'DEV_VM_POLICY_FETCH'") && strcontains(local.user_data_script, "<<'DEV_VM_POLICY_RUN'")
    error_message = "The scripts must be written through quoted heredocs; an unquoted one would expand their $ at first boot."
  }

  assert {
    condition     = strcontains(local.user_data_script, "the PolicyGroup tag must be staging or production") && !strcontains(local.user_data_script, "POLICY_GROUP=\"production\"")
    error_message = "An unknown PolicyGroup must fail closed; defaulting it to production turned a mistyped staging VM into a production one."
  }

  assert {
    condition     = !strcontains(local.user_data_script, "/tmp/cinc.deb") && !strcontains(local.user_data_script, "/tmp/aws")
    error_message = "Bootstrap downloads must not use predictable /tmp paths a developer logged in during first boot could swap before they run as root."
  }

  assert {
    condition     = strcontains(local.user_data_script, "[ \"$rc\" != 14 ]")
    error_message = "The first converge must retry exit 14 (nothing delivered yet) to ride out IAM propagation, and nothing else."
  }

  # EC2 refuses user data over 16 KB, measured before base64.
  assert {
    condition     = length(aws_instance.this["vm"].user_data_base64) * 3 / 4 < 16384
    error_message = "The gzipped user data must stay under EC2's 16 KB limit."
  }
}

run "bootstrap_reads_only_its_own_policy" {
  command = plan

  assert {
    condition     = !strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "cinc")
    error_message = "No CINC validator grant may remain on the bootstrap role."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "\"arn:aws:s3:::tenant-policies/dev-vm-policies/dev-vm/*\"")
    error_message = "The bootstrap role must read exactly its own policy's prefix."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "s3:ListBucket") && !strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "s3:*")
    error_message = "The bootstrap role fetches exact keys; it gets no ListBucket and no wildcard."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "kms:Decrypt")
    error_message = "With no policy_kms_key_arn there is nothing to decrypt with."
  }
}

run "kms_bucket_adds_decrypt_and_key_denies" {
  command = plan
  variables {
    policy_kms_key_arn = "arn:aws:kms:eu-central-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  # IAM refuses a managed policy over 6,144 characters (whitespace excluded;
  # jsonencode emits none). The boundary is the longest document this module
  # writes and grows with every deny entry; this run has the most statements,
  # and the 1,500 left over is for the Allow list a VM's bundles declare.
  assert {
    condition     = length(aws_iam_policy.identity_boundary["vm"].policy) < 6144 - 1500
    error_message = "The identity boundary is too close to IAM's 6,144-character managed-policy limit: ${length(aws_iam_policy.identity_boundary["vm"].policy)} characters."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.bootstrap["vm"].policy, "kms:Decrypt")
    error_message = "With SSE-KMS the bootstrap role needs kms:Decrypt on the key."
  }

  assert {
    condition = alltrue([for a in ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy", "kms:CreateGrant"] :
    strcontains(aws_iam_policy.identity_boundary["vm"].policy, "\"${a}\"")])
    error_message = "The boundary must deny tampering with the key the fleet decrypts its policy with."
  }
}

run "boundary_denies_writes_to_the_policy_bucket" {
  command = plan

  # Found by a security review of the first version of this list. Each is one
  # call that stops every VM reading the bucket: requester-pays makes their
  # GETs fail, an archive tier makes objects unreadable, and a DNS, DHCP or
  # VPC-endpoint change black-holes S3 (and Loki) for the whole subnet —
  # a gateway endpoint adds its routes without ec2:CreateRoute. Tenth instance
  # of the multi-call-path omission.
  assert {
    condition = alltrue([
      for action in [
        "s3:PutBucketRequestPayment", "s3:PutIntelligentTieringConfiguration", "s3:PutBucketTagging",
        "s3:CreateAccessPointForObjectLambda", "s3:PutAccessPointPolicyForObjectLambda",
        "ec2:ModifyVpcAttribute", "ec2:AssociateDhcpOptions",
        "ec2:CreateVpcEndpoint", "ec2:ModifyVpcEndpoint",
        "route53resolver:AssociateFirewallRuleGroup", "route53resolver:AssociateResolverRule",
        ] : anytrue([
          for st in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
          st.Effect == "Deny" && anytrue([
            for p in flatten([st.Action]) : can(regex("^${replace(p, "*", ".*")}$", action))
          ])
      ])
    ])
    error_message = "The boundary must deny the one-call routes that freeze policy delivery fleet-wide."
  }

  # Siblings, not just the action a review happened to name: each of these
  # reaches the same asset as one already denied. Checked semantically — is
  # the action matched by some Deny pattern, wildcards included — because the
  # boundary now denies whole families with wildcards to stay inside IAM's
  # 6,144-character limit and to cover siblings by construction.
  assert {
    condition = alltrue([
      for action in [
        # IMDS switched off on a peer takes its bootstrap role.
        "ec2:ModifyInstanceMetadataOptions", "ec2:ModifyInstanceMetadataDefaults",
        # A whole region's egress, or the region.
        "ec2:ModifyVpcBlockPublicAccessOptions", "ec2:DeleteVpcBlockPublicAccessExclusion",
        "ec2:ModifyVpcBlockPublicAccessExclusion", "account:DisableRegion",
        # Gateway endpoints add their own routes; their policy can deny the bucket.
        "ec2:CreateVpcEndpoint", "ec2:ModifyVpcEndpoint", "ec2:DeleteVpcEndpoints",
        # DNS for the VPC.
        "ec2:ModifyVpcAttribute", "ec2:AssociateDhcpOptions",
        "route53resolver:AssociateFirewallRuleGroup", "route53resolver:UpdateFirewallRule",
        "route53resolver:CreateFirewallRule", "route53resolver:UpdateFirewallRuleGroupAssociation",
        "route53resolver:UpdateFirewallConfig", "route53resolver:UpdateFirewallDomains",
        "route53resolver:AssociateResolverRule", "route53resolver:UpdateResolverRule",
        # A peer's name: its fqdn is its EIP.
        "ec2:AssociateAddress", "ec2:DisassociateAddress", "ec2:ReleaseAddress", "ec2:ModifyAddressAttribute",
        # Peers' availability.
        "ec2:SendDiagnosticInterrupt",
        # A private zone on the fleet's VPC overrides any public name — the
        # S3 endpoint, Loki — for every VM; Profiles and Cloud Map attach
        # zones and resolver rules to a VPC from their own namespaces.
        "route53:CreateHostedZone", "route53:AssociateVPCWithHostedZone",
        "route53:CreateVPCAssociationAuthorization",
        "route53profiles:AssociateProfile", "route53profiles:AssociateResourceToProfile",
        "servicediscovery:CreatePrivateDnsNamespace", "servicediscovery:UpdatePrivateDnsNamespace",
        # The fleet's zone.
        "route53:ChangeResourceRecordSets", "route53:DeleteHostedZone",
        "route53:EnableHostedZoneDNSSEC", "route53:DisableHostedZoneDNSSEC",
        "route53:CreateKeySigningKey", "route53:ActivateKeySigningKey",
        "route53:DeactivateKeySigningKey", "route53:DeleteKeySigningKey",
        ] : anytrue([
          for st in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
          st.Effect == "Deny" && anytrue([
            for p in flatten([st.Action]) : can(regex("^${replace(p, "*", ".*")}$", action))
          ])
      ])
    ])
    error_message = "Every sibling route to a peer's IMDS, its name, the region's egress or the VPC's DNS must be denied."
  }

  # Wildcards must not swallow the reads a developer legitimately needs.
  assert {
    condition = alltrue([
      for action in ["ec2:DescribeAddresses", "ec2:DescribeInstances", "route53:ListHostedZones"] : !anytrue([
        for st in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
        st.Effect == "Deny" && anytrue([
          for p in flatten([st.Action]) : can(regex("^${replace(p, "*", ".*")}$", action))
        ])
      ])
    ])
    error_message = "A deny wildcard matches a read-only call it was never meant to cover."
  }

  # Unconditionally: a deny conditioned on a key the request never carries
  # is a no-op, and route53:VPCs on CreateHostedZone has not been verified.
  assert {
    condition = anytrue([
      for st in jsondecode(aws_iam_policy.identity_boundary["vm"].policy).Statement :
      st.Effect == "Deny" && contains(flatten([st.Action]), "route53:CreateHostedZone") && try(st.Condition, null) == null
    ])
    error_message = "CreateHostedZone must be denied with no condition attached."
  }

  assert {
    condition     = strcontains(aws_iam_policy.identity_boundary["vm"].policy, "arn:aws:route53:::hostedzone/Z00000000000000000TEST")
    error_message = "Zone changes must be denied on the fleet's own zone, and only there."
  }

  assert {
    condition = alltrue([
      for action in [
        "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion",
        "s3:PutObjectRetention", "s3:PutObjectLegalHold", "s3:BypassGovernanceRetention",
        "s3:PutObjectAcl", "s3:PutObjectTagging",
        "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutLifecycleConfiguration",
        "s3:PutBucketVersioning", "s3:PutBucketObjectLockConfiguration", "s3:PutEncryptionConfiguration",
        "s3:DeleteBucket",
        "s3:CreateAccessPoint", "s3:PutAccessPointPolicy", "s3:CreateMultiRegionAccessPoint",
        "s3:CreateAccessGrant", "s3:CreateJob",
      ] : strcontains(aws_iam_policy.identity_boundary["vm"].policy, "\"${action}\"")
    ])
    error_message = "Every route to rewriting, deleting, locking or re-encrypting the policy bucket must be denied (AGENTS.md trap 1)."
  }

  assert {
    # The whole bucket, not just the prefix: measured on a live VM 2026-10-16,
    # a prefix-scoped deny still let an s3:* bundle write any other key.
    condition     = strcontains(aws_iam_policy.identity_boundary["vm"].policy, "\"Resource\":\"arn:aws:s3:::tenant-policies/*\"") && !strcontains(aws_iam_policy.identity_boundary["vm"].policy, "tenant-policies/dev-vm-policies/*")
    error_message = "Object writes are denied on every key in the policy bucket, and on nothing outside it."
  }

  assert {
    condition     = strcontains(aws_iam_policy.identity_boundary["vm"].policy, "\"Resource\":\"arn:aws:s3:::tenant-policies\"")
    error_message = "Bucket configuration writes are denied on the policy bucket."
  }

  assert {
    condition     = !strcontains(aws_iam_policy.identity_boundary["vm"].policy, "kms:")
    error_message = "With no policy_kms_key_arn the boundary has no KMS key to protect."
  }
}
