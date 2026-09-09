locals {
  default_tags = merge(var.tags, {
    Environment = var.environment
    Region      = var.aws_region
    ManagedBy   = "Terraform"
  })
}

# Security group
resource "aws_security_group" "ec2" {
  region      = var.aws_region
  name        = "${var.environment}-ec2-sg"
  description = "Security group for EC2 instances"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(local.default_tags, {
    Name = "${var.environment}-ec2-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "rules" {
  for_each = var.security_group_rules

  region            = var.aws_region
  security_group_id = aws_security_group.ec2.id
  type              = each.value.type
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  protocol          = each.value.protocol
  cidr_blocks       = each.value.cidr_blocks
  description       = each.value.description
}

# AMI lookup. `region` matters here: an AMI ID is region-scoped, so without it
# every region would launch the us-east-1 image ID and fail.
data "aws_ami" "latest" {
  region      = var.aws_region
  most_recent = true
  owners      = var.ami_owners

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Elastic IPs
resource "aws_eip" "this" {
  for_each = var.instances

  region = var.aws_region
  domain = "vpc"

  tags = merge(local.default_tags, each.value.tags, {
    Name = "${each.key}-eip"
  })
}

# EC2 instances
resource "aws_instance" "this" {
  for_each = var.instances

  region        = var.aws_region
  ami           = each.value.ami_id != null ? each.value.ami_id : data.aws_ami.latest.id
  instance_type = each.value.instance_type
  subnet_id     = local.subnet_ids[coalesce(each.value.az, var.default_az)]
  key_name      = each.value.key_name

  iam_instance_profile        = aws_iam_instance_profile.bootstrap[each.key].name
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.ec2.id]

  user_data_base64 = base64encode(local.user_data_script)

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size = each.value.volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  # PolicyName and PolicyGroup travel as tags rather than through user_data,
  # because user_data is one shared script for every instance in the region and
  # so cannot carry per-instance values. The script reads both back over IMDS.
  #
  # The idlefy map is FIRST on purpose. local.default_tags already folds in the
  # fleet-wide var.tags, so with the flag ahead of it both a fleet-wide
  # tags = { idlefy = "disabled" } and a per-VM one override the flag, and no
  # second variable is needed. Lowercase `idlefy` is Idlefy's canonical key —
  # its IAM condition (ec2:ResourceTag/idlefy = enabled) reads nothing else.
  tags = merge(
    var.idlefy_managed ? { idlefy = "enabled" } : {},
    local.default_tags,
    each.value.tags,
    {
      Name        = each.key
      PolicyName  = each.value.policy_name
      PolicyGroup = each.value.policy_group
    },
  )

  depends_on = [
    aws_ssm_parameter.access,
    aws_iam_role.identity,
    # The inline policy is what actually grants the ssm:GetParameter the first
    # boot performs (iam.tf, aws_iam_role_policy.bootstrap). Without it the
    # policy and the instance are unordered siblings, and a boot that beats the
    # policy write dies at the validator-key fetch under set -e and never
    # self-heals. This orders CREATION; IAM propagation delay after the write
    # survives it — the race shrinks, it does not vanish.
    aws_iam_role_policy.bootstrap,
  ]

  lifecycle {
    # ami: the pattern moves forward, running VMs stay — see var.ami_name_pattern.
    # user_data_base64: the bootstrap script runs ONCE, at first boot.
    # cloud-init never re-runs it on an existing instance, but the provider
    # would still stop/start every running VM in the region to rewrite the
    # attribute — a fleet-wide hard reboot that achieves nothing. Script
    # changes (CINC_VERSION bumps included — cinc_client.rb calls this pin the
    # "bootstrap floor") reach new instances only; to re-bootstrap an existing
    # VM, recreate it deliberately.
    ignore_changes = [ami, user_data_base64]
  }
}

# EIP association
resource "aws_eip_association" "this" {
  for_each = var.instances

  region        = var.aws_region
  instance_id   = aws_instance.this[each.key].id
  allocation_id = aws_eip.this[each.key].id
}
