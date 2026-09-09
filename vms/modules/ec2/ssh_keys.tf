# Create SSH keys for developers
resource "aws_key_pair" "developers" {
  for_each = var.ssh_key_pairs

  region     = var.aws_region
  key_name   = each.key
  public_key = each.value

  tags = merge(local.default_tags, {
    Name = each.key
  })
}
