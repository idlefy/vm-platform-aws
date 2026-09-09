locals {
  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      Region      = var.aws_region
      ManagedBy   = "Terraform"
      Account     = var.account_name
    }
  )
  # Flatten SG rules: { "cinc.ssh" => rule, "cinc.https" => rule, ... }
  sg_rules_flat = merge([
    for inst_key, inst in var.instances : {
      for rule_key, rule in inst.security_group_rules :
      "${inst_key}.${rule_key}" => merge(rule, { instance_key = inst_key })
    }
  ]...)
}

# Per-instance security group
resource "aws_security_group" "this" {
  for_each = var.instances

  name        = "${var.environment}-${each.key}-sg"
  description = "Security group for ${each.key}"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.environment}-${each.key}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "rules" {
  for_each = local.sg_rules_flat

  security_group_id = aws_security_group.this[each.value.instance_key].id
  type              = each.value.type
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  protocol          = each.value.protocol
  cidr_blocks       = each.value.cidr_blocks
  description       = each.value.description
}

# Per-instance EIP
resource "aws_eip" "this" {
  for_each = var.instances
  domain   = "vpc"

  tags = merge(local.common_tags, each.value.tags, {
    Name = "${var.environment}-${each.key}-eip"
  })
}

# Per-instance EC2
resource "aws_instance" "this" {
  for_each = var.instances

  ami                         = var.ami_id
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.public.id
  key_name                    = each.value.key_name
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.this[each.key].id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    master_ssh_keys = local.master_ssh_keys_formatted
    ufw_ports       = each.value.ufw_ports
  }))

  root_block_device {
    volume_size = each.value.volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.common_tags, each.value.tags, {
    Name = "${var.environment}-${each.key}"
  })

}

resource "aws_eip_association" "this" {
  for_each      = var.instances
  instance_id   = aws_instance.this[each.key].id
  allocation_id = aws_eip.this[each.key].id
}
