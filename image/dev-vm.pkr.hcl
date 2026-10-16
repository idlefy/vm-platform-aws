# A tenant-built image: one converge of the tenant's promoted production
# revision, scrubbed of everything that belongs to the build instance.
# Design: docs/design/ami-image.md. Run it through the tenant's `make ami`,
# which supplies every variable from the tenant's vms/ — never by hand.
packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

variable "aws_profile" { type = string }
variable "build_region" { type = string }
variable "ami_regions" { type = list(string) }
variable "user_data_file" { type = string }
variable "policy_bucket" { type = string }
variable "policy_prefix" { type = string }
variable "policy_kms_key_arn" {
  type    = string
  default = ""
}
variable "policy_name" { type = string }
variable "revision_id" { type = string }
variable "platform_sha" { type = string }
variable "cookbook_version" { type = string }
variable "subnet_id" {
  type    = string
  default = ""
}
variable "instance_type" {
  type    = string
  default = "t3.large"
}
variable "volume_size_gb" {
  type    = number
  default = 20
}

locals {
  stamp = formatdate("YYYYMMDDhhmmss", timestamp())
  tags = {
    PolicyName      = var.policy_name
    RevisionId      = var.revision_id
    PlatformSha     = var.platform_sha
    CookbookVersion = var.cookbook_version
    BuiltBy         = "packer"
  }
}

source "amazon-ebs" "dev_vm" {
  profile       = var.aws_profile
  region        = var.build_region
  ami_regions   = [for r in var.ami_regions : r if r != var.build_region]
  ami_name      = "dev-vm-${var.policy_name}-${local.stamp}"
  instance_type = var.instance_type
  subnet_id     = var.subnet_id == "" ? null : var.subnet_id

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # The build converges through the same signed path every VM uses, reading
  # its tags from IMDS. Production only: one image feeds both groups, so a
  # staging build would put unpromoted content on production VMs.
  run_tags = {
    Name        = "dev-vm-image-build"
    PolicyName  = var.policy_name
    PolicyGroup = "production"
  }
  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"
  }

  # Read the bucket, nothing else. No SSM: no credential that outlives the
  # build is ever written to its disk (spec, decision 5).
  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:aws:s3:::${var.policy_bucket}/${var.policy_prefix}/*"]
    }
    dynamic "Statement" {
      for_each = var.policy_kms_key_arn == "" ? [] : [var.policy_kms_key_arn]
      content {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [Statement.value]
      }
    }
  }

  # Packer never connects: base::sudoers takes ubuntu's sudo mid-converge and
  # base::ssh restarts sshd. The instance scrubs itself and powers off; a build
  # that fails never powers off, and this wait times out with no AMI.
  communicator          = "none"
  disable_stop_instance = true
  user_data_file        = var.user_data_file
  aws_polling {
    delay_seconds = 15
    max_attempts  = 160
  }

  tags          = local.tags
  snapshot_tags = local.tags
}

build {
  sources = ["source.amazon-ebs.dev_vm"]
}
