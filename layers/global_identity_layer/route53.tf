resource "aws_route53_zone" "primary" {
  for_each = var.route53_hosted_zone_names

  name = each.value

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  route53_records_flat = flatten([
    for zone_name, records in var.route53_records : [
      for record in records : {
        key       = "${zone_name}|${record.name}|${upper(record.type)}"
        zone_name = zone_name
        name      = record.name
        type      = upper(record.type)
        ttl       = record.ttl
        records   = record.records
      }
    ]
  ])

  route53_records_map = {
    for record in local.route53_records_flat :
    record.key => record
  }
}

resource "aws_route53_record" "primary" {
  for_each = local.route53_records_map

  zone_id = aws_route53_zone.primary[each.value.zone_name].zone_id
  name    = each.value.name == "@" ? each.value.zone_name : each.value.name
  type    = each.value.type
  ttl     = each.value.ttl
  records = each.value.records
}
