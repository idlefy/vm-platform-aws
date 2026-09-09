variable "environment" {
  description = "Environment (dev, stage, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "network_config" {
  description = "Network configuration"
  type = object({
    vpc_cidr = string
    public_subnets = map(object({
      cidr_block = string
      az         = string
    }))
  })
}

variable "ssh_key_pairs" {
  description = "Developer SSH public keys (name => public key)"
  type        = map(string)
  default     = {}
}

variable "instances" {
  description = "EC2 instance configuration"
  type = map(object({
    instance_type  = string
    volume_size_gb = number
    az             = optional(string)
    fqdn           = string
    key_name       = string
    ami_id         = optional(string, null)
    policy_name    = optional(string, "dev-vm")
    policy_group   = optional(string, "production")
    aws_access     = optional(list(string), [])
    tags           = optional(map(string), {})
  }))
  default = {}

  # Only the two groups the CINC server actually carries. A typo here would
  # otherwise produce a VM whose client.rb names a group that does not exist,
  # and the failure surfaces as a VM that never converges — three minutes after
  # apply reported success, with nothing in the plan to suggest it.
  validation {
    condition = alltrue([
      for _, vm in var.instances : contains(["staging", "production"], vm.policy_group)
    ])
    error_message = "policy_group must be either \"staging\" or \"production\"."
  }

  validation {
    condition = alltrue([
      for name, _ in var.instances : can(regex("^[a-z][a-z0-9-]{1,33}$", name))
    ])
    error_message = "VM names must be 2-34 chars, lowercase letters/digits/hyphen, starting with a letter. This keeps 'dev-vm-boot-<name>-<region>' within IAM's 64-char role-name limit and within the sts:SourceIdentity character set."
  }
}

# Validation lives here, not in the calling root.
#
# This module is a published artifact: every consumer resolves it by
# `?ref=<sha>` and supplies its own root. If the checks lived in the root, each
# tenant would carry its own copy and they would diverge — which is the failure
# the previous version of this comment was written to avoid, back when there was
# exactly one root and it was in this repository.
#
# One narrowing to know about, measured: these are evaluated per region, because
# the root calls this module with `for_each = local.regions`. With no regions
# configured, `var.instances` is empty here and nothing is checked — an
# `access_bundles` entry containing a literal `*` plans clean. Every real tenant
# configures at least one region, so it is a narrowing and not a hole; the
# fleet-wide checks that must run regardless live in `modules/fleet-guards`.
variable "access_bundles" {
  description = "Named permission bundles, keyed by bundle name."
  type = map(object({
    description     = string
    policy_arns     = optional(list(string), [])
    allowed_actions = list(string)
  }))
  default = {}

  # allowed_actions has no default on purpose. A bundle that declares no ceiling
  # grants nothing, because the permissions boundary allows only what is declared
  # — so a defaulted empty list would be a silent no-op, which is the single
  # worst failure mode this design can have.
  validation {
    condition = alltrue([
      for _, b in var.access_bundles : length(b.allowed_actions) > 0
    ])
    error_message = "Every access_bundles entry needs a non-empty allowed_actions. It is the ceiling the VM's permissions boundary will allow; an empty list means the bundle's policies grant nothing at all."
  }

  validation {
    condition = alltrue([
      for _, b in var.access_bundles : !contains(b.allowed_actions, "*")
    ])
    error_message = "allowed_actions must not contain the literal \"*\". That turns the permissions boundary back into an open ceiling, which is precisely what it exists to prevent. List the service namespaces the bundle needs, e.g. [\"s3:*\", \"logs:*\"]."
  }

  validation {
    condition = alltrue([
      for _, b in var.access_bundles : alltrue([
        for a in b.allowed_actions : can(regex("^[a-z0-9-]+:[A-Za-z0-9*]+$", a))
      ])
    ])
    error_message = "Each allowed_actions entry must be of the form \"service:Action\", e.g. \"s3:*\" or \"logs:DescribeLogGroups\". A bare service name produces a MalformedPolicyDocument at apply time, which is a much worse place to find out."
  }

  # These four namespaces have no legitimate use in a developer bundle in phase A
  # and every one of them is a direct escalation path, so they are refused here
  # rather than left to the boundary's deny list. The deny list would in fact stop
  # them — this is about the mistake never reaching a reviewed apply at all.
  validation {
    condition = alltrue([
      for _, b in var.access_bundles : alltrue([
        for a in b.allowed_actions :
        !contains(["iam", "sts", "organizations", "ec2-instance-connect"], split(":", a)[0])
      ])
    ])
    error_message = "allowed_actions must not name the iam, sts, organizations or ec2-instance-connect namespaces. Each is a path from developer credentials to role manipulation or root on the VM. If a bundle genuinely needs one, that is a design discussion, not a tfvars edit."
  }
}

variable "default_az" {
  description = "Default AZ when instance az is not specified"
  type        = string
}

variable "security_group_rules" {
  description = "Security group rules for EC2 instances"
  type = map(object({
    type        = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
}

variable "route53_zone_id" {
  description = "Route53 zone ID for creating DNS records"
  type        = string
}

variable "cinc_ssm_parameter_name" {
  description = "SSM parameter name containing CINC validation key"
  type        = string

  # modules/ec2/iam.tf builds the grant by concatenation:
  # "arn:aws:ssm:<region>:<account>:parameter${var.cinc_ssm_parameter_name}".
  # Without the leading slash that yields ":parameterdeveloper-vms/..." — a
  # syntactically valid ARN matching no parameter. The plan applies, the policy
  # attaches, and the VM then fails at first boot with an AccessDenied on a name
  # that looks correct in the console.
  # The regex, not startswith(): "/" on its own also starts with a slash, and SSM
  # has no parameter at the bare root, so that value would pass the check and then
  # fail exactly the way a missing slash does.
  validation {
    condition     = can(regex("^/.+", var.cinc_ssm_parameter_name))
    error_message = "cinc_ssm_parameter_name must start with \"/\" and name something after it (e.g. \"/developer-vms/cinc/myorg-validator-key\"). The IAM grant concatenates this onto \":parameter\", so a missing slash produces a policy that matches nothing and a VM that cannot bootstrap."
  }
}

variable "log_shipping" {
  description = "Ship the VM journal to Grafana Cloud Loki. Twin of the cookbook attribute base.loki.enabled; `make preflight` in the tenant checks the two agree. When false the bootstrap role gets no grant on loki_ssm_parameter_name, which must then be null."
  type        = bool
  default     = true
}

variable "loki_ssm_parameter_name" {
  description = "SSM parameter name containing the Grafana Cloud Loki push token. Required when log_shipping is true; must be null when it is false (terraform_data.assert_log_shipping_inputs in iam.tf enforces both)."
  type        = string
  default     = null

  # Same concatenation as cinc_ssm_parameter_name, same silent failure, one
  # stage later: the VM boots and converges, dev-vm-loki-token exits 10 because
  # the fetch is denied, and the node ships no logs while reporting healthy.
  # `make preflight` catches this against the live account; this catches it at
  # plan time. Same regex-not-startswith reason: a bare "/" is not a parameter.
  # null is allowed here and judged in iam.tf against log_shipping — a
  # validation block cannot see another variable on this module's 1.5 floor.
  validation {
    condition     = var.loki_ssm_parameter_name == null || can(regex("^/.+", var.loki_ssm_parameter_name))
    error_message = "loki_ssm_parameter_name must start with \"/\" and name something after it (e.g. \"/developer-vms/observability/loki-token\"), or be null when log_shipping is false. The IAM grant concatenates this onto \":parameter\", so a missing slash denies the fetch and the VM ships no logs while looking healthy."
  }
}

variable "idlefy_managed" {
  description = <<-EOT
    Tag every instance `idlefy = "enabled"` so Idlefy discovers and manages it.
    The tag is a label only: the platform grants Idlefy nothing. Idlefy's own
    IAM role carries the boundary — its Start/Stop/Reboot permissions are
    conditioned on `ec2:ResourceTag/idlefy = enabled`, so an untagged VM is
    invisible to it. Set false and the module adds no `idlefy` tag of its own;
    an explicit `idlefy` entry in `tags` or in an instance's `tags` still
    applies either way — those maps are merged after this flag and win over
    it. A single VM opts out with `tags = { idlefy = "disabled" }` in
    `instances`.
  EOT
  type        = bool
  default     = true
}

variable "cinc_server_url" {
  description = "CINC server URL including organization"
  type        = string
}


variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}

variable "ami_owners" {
  description = "List of AMI owners"
  type        = list(string)
  default     = ["099720109477"] # Canonical
}

variable "ami_name_pattern" {
  description = "AMI name pattern for filtering"
  type        = string
  # `aws_instance` sets lifecycle.ignore_changes = [ami], so changing this does
  # not recreate running VMs — it only decides what a *new* VM launches with.
  # Pin `ami_id` per instance to hold a VM on an older release.
  #
  # 24.04 (noble), not 26.04 (resolute), and this is a deliberate step *back*
  # taken on 2026-08-05. 26.04 replaces core userland with Rust rewrites, and
  # they change the behaviour of the exact primitives this platform's security
  # controls rest on:
  #
  #   - `sudo-rs` is the default `sudo` (via update-alternatives). It logs
  #     successful sessions through PAM but writes **no record of a denied
  #     escalation attempt** — not to the journal, not to auth.log, and auditd
  #     is not installed. Verified on a live resolute VM against a user with no
  #     sudoers entry, across three paths (`sudo -n`, interactive with a wrong
  #     password, `sudo -l`): all refused, none logged, while successful sudo
  #     sessions in the same window were recorded normally. Developers have no
  #     sudo here, so an attempt is precisely the security event worth alerting
  #     on, and 26.04 makes it invisible. 24.04 ships classic sudo 1.9.15 and
  #     logs it as `user NOT in sudoers`. Re-testing this needs an interactive
  #     path — `sudo -n` alone logs nothing on classic sudo either, so a
  #     `-n`-only test falsely shows the two behaving the same.
  #   - `rust-coreutils` changes `stat` output formatting, which the credential
  #     broker's uid/mode gate parses (see the trap in CLAUDE.md).
  #   - CINC publishes no 26.04 build, so a resolute VM installs the 24.04
  #     omnibus package anyway — the config agent was already running on a
  #     compatibility workaround.
  #   - 26.04 is not on AWS's verified OS list, which is what disqualified
  #     GuardDuty Runtime Monitoring in the log-shipping design.
  #
  # All four disappear on 24.04, which is supported to 2029 (ESM 2034).
  default = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}
