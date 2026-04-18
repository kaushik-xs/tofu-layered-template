resource "aws_eip" "this" {
  for_each = var.elastic_ips

  domain = "vpc"

  tags = merge(
    {
      Name = each.key
    },
    try(each.value.tags, {})
  )
}
