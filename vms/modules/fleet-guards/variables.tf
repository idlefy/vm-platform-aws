# Fleet-wide guards: the checks that cannot live in modules/ec2 because they are
# only meaningful across every region at once.
#
# This module computes. It asserts nothing, and that is forced rather than
# chosen: `expect_failures` cannot name an object inside a child module, and a
# run block cannot point at a remote source, so a precondition living here would
# be unassertable by the only test a tenant runs. The calling root owns the
# assertions — see terraform_data.assert_no_duplicate_vm_names and
# terraform_data.assert_no_orphan_region_keys there.

variable "instances" {
  description = "Per-region instance definitions, exactly as the root declares them."

  # object({}) on purpose, not the per-VM schema. Measured: converting the real
  # per-VM objects to a narrower object type drops the extra attributes and
  # keys() still returns the VM names — so this module reads only what it needs
  # and does not have to be re-published every time modules/ec2 gains a per-VM
  # field. It never reads a value, only a key.
  type    = map(map(object({})))
  default = {}
}

variable "ssh_key_pairs" {
  description = "Per-region SSH public keys (region => name => pubkey)."

  # Not optional in practice. The orphan-region check reads BOTH maps: a
  # developer's key added under a region config.tf does not configure is caught
  # only by this half, and a caller that omits it silently halves the guard.
  type    = map(map(string))
  default = {}
}

variable "regions" {
  description = "Names of the regions the caller actually configures — keys(local.regions)."
  type        = set(string)
}
