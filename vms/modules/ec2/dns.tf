resource "aws_route53_record" "instances" {
  for_each = var.instances

  zone_id = var.route53_zone_id
  name    = each.value.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_eip.this[each.key].public_ip]
}
