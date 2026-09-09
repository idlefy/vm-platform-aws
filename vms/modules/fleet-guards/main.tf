# VM names must be unique across the whole fleet, not merely within a region, and
# nothing else enforces it: modules/ec2 validates the *shape* of each name per
# region, and its keys are only unique per map.
#
# What breaks is not Terraform. IAM role names carry the region, so they do not
# collide, and each VM gets its own instance — the plan looks entirely reasonable.
# The collision is downstream: user_data writes `node_name "$INSTANCE_NAME"` from
# the unqualified Name tag, so two same-named VMs register as ONE CINC node and
# then overwrite each other's attributes every 30 minutes. `make node-delete
# NODE=<name>` cannot say which one it means, and outputs.instance_ids merges the
# regional maps, so one of the two silently disappears from every consumer that
# resolves a VM by name.
locals {
  all_vm_names = flatten([for region, vms in var.instances : keys(vms)])

  duplicate_vm_names = distinct([
    for name in local.all_vm_names : name
    if length([for n in local.all_vm_names : n if n == name]) > 1
  ])
}

# A region key that matches nothing in the caller's configured set builds no
# resources and reports no error: the VM listed under it simply never exists.
# That is the failure mode the single-provider for_each refactor introduced, and
# it is why this is computed rather than left to a variable validation — the
# valid set lives in a local, and variable validation cannot reference locals.
locals {
  orphan_region_keys = distinct([
    for k in concat(keys(var.instances), keys(var.ssh_key_pairs)) : k
    if !contains(var.regions, k)
  ])
}
