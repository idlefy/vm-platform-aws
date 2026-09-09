resource "aws_key_pair" "this" {
  for_each = var.ssh_key_pairs

  key_name   = each.key
  public_key = each.value

  tags = merge(local.common_tags, {
    Name = each.key
  })
}
