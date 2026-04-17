resource "aws_route53_zone" "primary" {
  for_each = var.route53_hosted_zone_names

  name = each.value

  lifecycle {
    prevent_destroy = true
  }
}
