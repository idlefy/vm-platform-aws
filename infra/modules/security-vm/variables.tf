variable "environment" {
  description = "Environment (dev, stage, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "account_name" {
  description = "AWS account name used for tagging"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_az" {
  description = "Availability zone for the subnet"
  type        = string
}

variable "ssh_key_pairs" {
  description = "SSH public keys (name => public key)"
  type        = map(string)
  default     = {}
}

variable "master_ssh_keys" {
  description = "Master SSH public keys added to root user"
  type        = list(string)
  default     = []
}

variable "instances" {
  description = "Map of security VM instances"
  type = map(object({
    instance_type  = string
    volume_size_gb = optional(number, 100)
    key_name       = string
    fqdn           = string
    ufw_ports      = list(string)
    tags           = optional(map(string), {})
    security_group_rules = map(object({
      type        = string
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = list(string)
      description = string
    }))
  }))
}

variable "route53_zone_id" {
  description = "Route53 zone ID"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}

variable "ami_id" {
  description = "AMI ID for instances (pin to avoid unplanned replacements)"
  type        = string
}
