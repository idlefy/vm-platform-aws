output "instances" {
  description = "Map of instance details"
  value = {
    for k, v in aws_instance.this : k => {
      instance_id = v.id
      private_ip  = v.private_ip
      elastic_ip  = aws_eip.this[k].public_ip
      fqdn        = var.instances[k].fqdn
    }
  }
}

output "security_group_ids" {
  description = "Map of security group IDs"
  value       = { for k, v in aws_security_group.this : k => v.id }
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}
