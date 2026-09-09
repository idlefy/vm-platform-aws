# Per-tenant variables — fill in tenant.auto.tfvars (see tenant.auto.tfvars.example).

variable "aws_profile" {
  description = "AWS CLI profile used by the provider block."
  type        = string
}

variable "account_name" {
  description = "AWS account display name (used in resource tags)."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the CINC A-record."
  type        = string
}

variable "cinc_server_fqdn" {
  description = "FQDN for the CINC server, e.g. cinc.infra.example.com."
  type        = string
}


variable "ssh_key_pairs" {
  description = "Per-server SSH public keys placed as AWS key pairs (key_pair name => pubkey)."
  type        = map(string)
}

variable "master_ssh_keys" {
  description = "Ops SSH public keys appended to authorized_keys on the infra servers (root/admin access)."
  type        = list(string)
}
