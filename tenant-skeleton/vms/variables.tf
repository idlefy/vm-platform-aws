# Per-tenant variables — fill in tenant.auto.tfvars (see tenant.auto.tfvars.example).
# Per-VM variables (`instances`, `ssh_key_pairs`) come from instances.auto.tfvars.
#
# Declarations only. Input validation lives in the published modules —
# `modules/ec2/variables.tf` for anything scoped to one region, and
# `modules/fleet-guards` for the two fleet-wide guards this root asserts on.
# Duplicating a check here would mean two copies to keep in step across every
# tenant, which is exactly what publishing the module is meant to end.

variable "aws_profile" {
  description = "AWS CLI profile used by the provider blocks."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for VM DNS A-records (e.g. Z0123456789ABCDEFGHIJ)."
  type        = string
}

variable "cinc_ssm_parameter_name" {
  description = "SSM parameter holding the CINC validation key (SecureString). Created once per region."
  type        = string
}

variable "log_shipping" {
  description = "Ship the VM journal to Grafana Cloud Loki. Twin of `default['base']['loki']['enabled']` in cinc/policyfiles/dev-vm.rb; `cd cinc && make preflight` checks the two agree. false ⇒ loki_ssm_parameter_name must be null."
  type        = bool
  default     = true
}

variable "loki_ssm_parameter_name" {
  description = "SSM parameter holding the Grafana Cloud Loki push token (SecureString). Created by hand in each region, never by Terraform — the value must not enter state. null when log_shipping is false."
  type        = string
  default     = null
}

variable "idlefy_managed" {
  description = <<-EOT
    Tag every VM `idlefy = "enabled"` so Idlefy manages it — see the ec2 module's variable of the same name for what that does (and does not) grant.
    false ⇒ the module adds no `idlefy` tag; an explicit `idlefy` entry in a VM's `tags` still applies. One VM opts out via `tags = { idlefy = "disabled" }` in instances.auto.tfvars.
  EOT
  type        = bool
  default     = true
}

variable "cinc_server_url" {
  description = "Full CINC server URL including the org path (e.g. https://cinc.example.com/organizations/myorg)."
  type        = string
}


variable "access_bundles" {
  description = "Named permission bundles referenced by instances[*].aws_access. Phase A: same-account managed policies only."
  type = map(object({
    description     = string
    policy_arns     = optional(list(string), [])
    allowed_actions = list(string)
  }))
  default = {}
}

# Per-VM definitions, populated by instances.auto.tfvars
variable "instances" {
  description = "Per-region instance definitions."
  type = map(map(object({
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
  })))
}

variable "ssh_key_pairs" {
  description = "Per-region SSH public keys (region => name => pubkey)."
  type        = map(map(string))
}

# The AMI these VMs launch with. Declared here, in the tenant's own tree, for
# two reasons: `scripts/add-region.sh` reads the pattern to check that a new
# region actually has a matching image, and it cannot read a module it does not
# have on disk; and a change of base image should appear in the tenant's own
# diff rather than arriving with a pin bump.
#
# 24.04 (noble), and 26.04 is not an upgrade waiting to be applied — it was
# rolled back on 2026-08-05 on purpose. 26.04 replaces core userland with Rust
# rewrites that change the primitives this platform's security controls rest on,
# and every failure is silent: sudo-rs writes no record of a DENIED escalation
# attempt, rust-coreutils changes the `stat` output the credential broker parses,
# and CINC publishes no 26.04 build. Developers have no sudo here, so a refused
# attempt is exactly the event worth alerting on.
#
# The evidence is in the pinned upstream checkout, at
# .terraform/modules/ec2/vms/modules/ec2/variables.tf and in its CLAUDE.md.
# If a future release has to be adopted, the gate is a live VM — check sudo
# denial logging on an INTERACTIVE path, `stat -c '%u'` output, and whether CINC
# ships a build. Not a changelog.
variable "ami_name_pattern" {
  description = "AMI name filter for new VMs. Changing this does not recreate running VMs — aws_instance ignores changes to ami."
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

variable "ami_owners" {
  description = "AMI owner account IDs. 099720109477 is Canonical."
  type        = list(string)
  default     = ["099720109477"]
}
