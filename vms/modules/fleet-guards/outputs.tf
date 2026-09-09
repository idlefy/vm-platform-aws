output "duplicate_vm_names" {
  description = "VM names appearing in more than one region. Empty means the fleet is clean."
  value       = local.duplicate_vm_names
}

output "orphan_region_keys" {
  description = "Region keys used by instances or ssh_key_pairs that the caller does not configure."
  value       = local.orphan_region_keys
}
