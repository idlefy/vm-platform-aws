# Idlefy's public hardened image for AI agents: one solo converge of the base
# cookbook, scrubbed with the solo profile, published by Idlefy's own account
# as idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN. Run it through
# scripts/hardened-image-build.sh, which supplies every variable — never by hand.
#
# It lives in its own directory because Packer loads every *.pkr.hcl in a
# directory as one build: next to ../dev-vm.pkr.hcl it would redeclare that
# template's variables and `packer validate .` would fail on both.
#
# No instance profile of any kind: the build fetches its policy archive from a
# public release asset and checks the sha256 pinned in its user data, so it
# needs no credential, and the publishing role is denied iam:PassRole.
# Unencrypted root: AWS refuses to share an encrypted AMI publicly. A consumer
# encrypts the disk when it launches the image.
# A fixed security group is passed in, so Packer never creates a temporary one
# and the publishing role needs no security-group rights.
# Design record: docs/design/hardened-image.md.
packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = ""
}
variable "build_region" { type = string }
variable "ami_regions" { type = list(string) }
# The name consumers match on: the driver computes it, and nothing else may.
variable "ami_name" {
  type = string
  validation {
    condition     = can(regex("^idlefy-hardened-agent-ubuntu-24\\.04-amd64-[0-9]{8}-[0-9]{2}$", var.ami_name))
    error_message = "The ami_name must be idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN."
  }
}
variable "user_data_file" { type = string }
variable "instance_type" {
  type    = string
  default = "c7a.xlarge"
}
variable "subnet_id" {
  type    = string
  default = ""
}
variable "security_group_id" { type = string }
variable "volume_size_gb" {
  type    = number
  default = 20
}
variable "public" {
  type    = bool
  default = true
}
variable "platform_tag" { type = string }
variable "platform_sha" { type = string }
variable "base_tag" { type = string }
variable "archive_sha256" { type = string }
variable "attached_org_id" {
  type    = string
  default = ""
}

locals {
  tags = merge({
    Name                 = var.ami_name
    IdlefyPublishedImage = "true"
    IdlefyImage          = "ubuntu-24.04-hardened"
    PlatformTag          = var.platform_tag
    PlatformSha          = var.platform_sha
    BaseTag              = var.base_tag
    ArchiveSha256        = var.archive_sha256
    BuiltBy              = "packer"
  }, var.attached_org_id == "" ? {} : { IdlefyAttached = var.attached_org_id })
}

source "amazon-ebs" "hardened" {
  profile     = var.aws_profile == "" ? null : var.aws_profile
  region      = var.build_region
  ami_regions = [for r in var.ami_regions : r if r != var.build_region]
  ami_name    = var.ami_name
  ami_groups  = var.public ? ["all"] : null
  # Retention reads "ever published" from this: a disabled image is private,
  # whether it was yanked or never public. The plugin sets it on the image and
  # on every regional copy in the same step as ami_groups; the fence deny
  # keeps anyone else from changing it. The release record carries the same
  # string (scripts/hardened-image-build.sh) — change both together.
  ami_description    = "Idlefy hardened image for AI agents; visibility=${var.public ? "public" : "private"}"
  encrypt_boot       = false
  instance_type      = var.instance_type
  subnet_id          = var.subnet_id == "" ? null : var.subnet_id
  security_group_ids = [var.security_group_id]

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
    encrypted             = false
    delete_on_termination = true
  }

  # The publishing role may only run, stop and terminate instances and volumes
  # that carry this Name, which none of the account's other machines do.
  run_tags = {
    Name = "idlefy-hardened-image-build"
  }
  run_volume_tags = {
    Name = "idlefy-hardened-image-build"
  }
  # The solo converge reads nothing from IMDS tags: everything it needs is in
  # its user data.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Packer never connects: base::sudoers takes ubuntu's sudo mid-converge and
  # base::ssh restarts sshd. The instance scrubs itself and powers off; a build
  # that fails never powers off, and this wait times out with no AMI.
  communicator          = "none"
  disable_stop_instance = true
  user_data_file        = var.user_data_file
  # The same budget as the fleet template: 15 s x 480 = 2 h for each wait.
  aws_polling {
    delay_seconds = 15
    max_attempts  = 480
  }

  tags          = local.tags
  snapshot_tags = local.tags
}

build {
  sources = ["source.amazon-ebs.hardened"]
}
