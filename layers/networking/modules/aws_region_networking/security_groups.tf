# Per-VPC security group for instances that opt in (compute layers attach it by VPC).
# Egress is open so attached instances keep outbound internet / RDS access (this SG
# replaces the VPC default SG on the instance). SSH ingress is added per VPC from
# ssh_ranges_by_vpc; an empty range list yields an egress-only group.

locals {
  ssh_ranges_by_vpc = {
    for vpc_name, vpc in var.vpcs : vpc_name => (
      length(try(vpc.ssh_ingress_source_ranges, [])) > 0 ?
      vpc.ssh_ingress_source_ranges :
      var.ssh_ingress_source_ranges
    )
  }
}

resource "aws_security_group" "ssh" {
  for_each = var.vpcs

  name_prefix = "${each.key}-ssh-"
  vpc_id      = aws_vpc.this[each.key].id
  description = "SSH ingress + open egress for opt-in instances in VPC ${each.key}."

  dynamic "ingress" {
    for_each = length(local.ssh_ranges_by_vpc[each.key]) > 0 ? [1] : []
    content {
      description = "SSH from ${join(", ", local.ssh_ranges_by_vpc[each.key])}"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = local.ssh_ranges_by_vpc[each.key]
    }
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${each.key}-ssh" }, try(each.value.tags, {}))

  lifecycle {
    create_before_destroy = true
  }
}
