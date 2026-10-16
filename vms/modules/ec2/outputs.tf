output "instance_ids" {
  description = "Map of instance keys to their IDs"
  value       = { for k, v in aws_instance.this : k => v.id }
}

output "instance_private_ips" {
  description = "Map of instance keys to their private IP addresses"
  value       = { for k, v in aws_instance.this : k => v.private_ip }
}

output "instance_elastic_ips" {
  description = "Map of instance keys to their Elastic IP addresses"
  value       = { for k, v in aws_eip.this : k => v.public_ip }
}

output "instance_fqdns" {
  description = "Map of instance keys to their FQDNs"
  value       = { for k, v in var.instances : k => v.fqdn }
}

output "security_group_id" {
  description = "ID of the security group for EC2 instances"
  value       = aws_security_group.ec2.id
}

output "ssh_key_names" {
  description = "List of created SSH key names"
  value       = [for k, v in aws_key_pair.developers : k]
}

output "identity_role_arns" {
  description = "Map of instance keys to the ARN of their developer-facing identity role. This is the list handed to resource owners when requesting access."
  value       = { for k, v in aws_iam_role.identity : k => v.arn }
}

# The plain bootstrap script, exactly as main.tf ships it (gzipped there). The
# tenant's `make ami` appends the image-scrub stage to it and builds an AMI
# with the same first boot every VM runs — one renderer, no second copy.
output "bootstrap_user_data" {
  description = "The rendered first-boot script, uncompressed."
  value       = local.user_data_script
}
