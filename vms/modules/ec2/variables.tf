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

  # Only the two groups the bucket carries envelopes for. user_data refuses
  # any other PolicyGroup tag at first boot (fail closed), so a typo here would
  # otherwise surface as a VM that never bootstraps — minutes after apply
  # reported success, with nothing in the plan to suggest it.
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

  # policy_name is interpolated into the bootstrap grant's S3 resource ARN and
  # into the keys the VM fetches. A `*` or `?` would widen the grant to other
  # policies' envelopes; anything outside this shape is refused at first boot.
  validation {
    condition = alltrue([
      for _, vm in var.instances : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", vm.policy_name))
    ])
    error_message = "policy_name must be 1-63 chars of lowercase letters, digits and hyphens, starting with a letter or digit."
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

# ---- policy delivery ------------------------------------------------------------
# There is no CINC server. Each VM fetches a signed envelope and a
# `chef export --archive` tarball from a bucket the tenant owns, and converges
# in local mode. Design: docs/design/serverless-policy-delivery.md.

variable "policy_bucket" {
  description = "Name of the tenant-owned S3 bucket the policy archives and signed envelopes live in. The module never creates it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.policy_bucket))
    error_message = "policy_bucket must be an S3 bucket name: 3-63 characters, lowercase letters, digits, dots and hyphens."
  }
}

variable "policy_bucket_owner" {
  description = "12-digit ID of the account that owns policy_bucket. Every fetch passes it as --expected-bucket-owner, so a bucket deleted and re-created under the same name in another account is refused by S3."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.policy_bucket_owner))
    error_message = "policy_bucket_owner must be a 12-digit AWS account ID."
  }
}

variable "policy_bucket_region" {
  description = "Region of policy_bucket. It may differ from aws_region; one bucket serves every region of the fleet."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.policy_bucket_region))
    error_message = "policy_bucket_region must be an AWS region name such as \"eu-central-1\"."
  }
}

variable "policy_prefix" {
  description = "Key prefix inside policy_bucket under which <policy_name>/ lives. No leading or trailing slash."
  type        = string
  default     = "dev-vm-policies"

  # It is interpolated into the bootstrap grant's resource ARN and into every
  # S3 key the VM fetches. `*` or `?` would widen the grant; a leading or
  # trailing slash would make keys that match nothing.
  validation {
    condition     = can(regex("^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$", var.policy_prefix))
    error_message = "policy_prefix must be one or more path segments of letters, digits, '.', '_' and '-', separated by single slashes, with no leading or trailing slash."
  }
}

variable "policy_kms_key_arn" {
  description = "ARN of the KMS key policy_bucket encrypts with, if it uses SSE-KMS. null for SSE-S3. When set, the bootstrap role gets kms:Decrypt on it; the key policy must allow that too."
  type        = string
  default     = null

  validation {
    condition     = var.policy_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.policy_kms_key_arn))
    error_message = "policy_kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>) or null. An alias ARN is refused: the grant would follow whatever key the alias is pointed at later."
  }
}

variable "policy_signers" {
  description = <<-EOT
    The keys a VM trusts at first boot, one allowed_signers line each:
      <principal> namespaces="dev-vm-policy-staging[,dev-vm-policy-production]"[,valid-before="YYYYMMDD"] ssh-ed25519 <key>
    After first boot the cookbook attribute base.policy.signers governs; the two
    are twins and `make preflight` checks that they agree.
  EOT
  type        = list(string)

  # The same shape base::cinc_client (libraries/policy_signers.rb) enforces.
  # namespaces= is mandatory — without it a staging-only key signs production —
  # and cert-authority lines are refused, since they would trust every key a CA
  # ever signed. The lines are written verbatim into a quoted heredoc at first
  # boot, so the shape is also what keeps them from carrying anything else.
  validation {
    condition = length(var.policy_signers) > 0 && alltrue([
      for l in var.policy_signers : can(regex(
        "^[A-Za-z0-9._@-]+ namespaces=\"dev-vm-policy-(staging|production)(,dev-vm-policy-(staging|production))?\"(,valid-before=\"[0-9]{8}([0-9]{4}([0-9]{2})?)?Z?\")? (ssh-ed25519|sk-ssh-ed25519@openssh\\.com) [A-Za-z0-9+/]+={0,2}$",
        l
      ))
    ])
    error_message = "policy_signers must hold at least one line of the form <principal> namespaces=\"dev-vm-policy-staging[,dev-vm-policy-production]\" ssh-ed25519 <key>. cert-authority lines and lines without namespaces= are refused."
  }
}

variable "policy_min_serial" {
  description = "The lowest envelope serial any VM accepts, first boot included. A new VM has no history to compare against; raise this to a security fix's serial so nothing older converges anywhere."
  type        = number
  default     = 0

  validation {
    condition     = var.policy_min_serial >= 0 && floor(var.policy_min_serial) == var.policy_min_serial && var.policy_min_serial < 1000000000000
    error_message = "policy_min_serial must be a whole number of Unix seconds, 0 or more."
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

  # modules/ec2/iam.tf builds the grant by concatenation:
  # "arn:aws:ssm:<region>:<account>:parameter${var.loki_ssm_parameter_name}".
  # Without the leading slash that is a valid ARN matching no parameter: the VM
  # boots and converges, dev-vm-loki-token exits 10 because the fetch is
  # denied, and the node ships no logs while reporting healthy.
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
