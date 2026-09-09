output "security_vms" {
  description = "Security VM details"
  value       = module.security.instances
}

output "vpc_id" {
  description = "Security VPC ID"
  value       = module.security.vpc_id
}
