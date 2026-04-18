locals {
  instances = var.instances
}

data "aws_ami" "amazon_linux_2023" {
  count       = length(local.instances) > 0 ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_subnet" "instance" {
  for_each = local.instances

  id = var.subnet_ids[each.value.subnet_key]
}

data "aws_security_group" "vpc_default" {
  for_each = local.instances

  vpc_id = data.aws_subnet.instance[each.key].vpc_id

  filter {
    name   = "group-name"
    values = ["default"]
  }
}

resource "aws_instance" "this" {
  for_each = local.instances

  ami           = coalesce(try(each.value.ami_id, null), data.aws_ami.amazon_linux_2023[0].id)
  instance_type = try(each.value.instance_type, "t3.micro")
  subnet_id     = data.aws_subnet.instance[each.key].id

  private_ip = try(each.value.private_ip, null)

  vpc_security_group_ids = length(try(each.value.security_group_ids, [])) > 0 ? each.value.security_group_ids : [data.aws_security_group.vpc_default[each.key].id]

  user_data = try(each.value.user_data, null)

  tags = merge(
    {
      Name = try(each.value.name, each.key)
    },
    try(each.value.vpc_name, null) != null ? { vpc = each.value.vpc_name } : {},
    try(each.value.network_name, null) != null ? { network = each.value.network_name } : {},
    try(each.value.tags, {})
  )

  lifecycle {
    precondition {
      condition     = contains(keys(var.subnet_ids), each.value.subnet_key)
      error_message = "subnet_key must exist in subnet_ids from networking state."
    }
  }
}
