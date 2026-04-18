locals {
  instances = var.instances

  instances_with_static_eip = {
    for k, v in local.instances : k => v
    if try(v.external_static_ip_key, null) != null && trimspace(tostring(v.external_static_ip_key)) != ""
  }
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

# Ubuntu Server 24.04 LTS (Noble); update the name filter when a new LTS becomes the default you want.
data "aws_ami" "ubuntu_lts" {
  count       = length(local.instances) > 0 ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
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

  ami = coalesce(
    try(each.value.ami_id, null) != null && trimspace(tostring(each.value.ami_id)) != "" ? each.value.ami_id : null,
    try(each.value.os, "amazon-linux-2023") == "ubuntu-server-lts" ? data.aws_ami.ubuntu_lts[0].id : data.aws_ami.amazon_linux_2023[0].id
  )
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

resource "aws_eip_association" "static" {
  for_each = local.instances_with_static_eip

  instance_id   = aws_instance.this[each.key].id
  allocation_id = var.elastic_ip_allocation_ids[each.value.external_static_ip_key]

  lifecycle {
    precondition {
      condition     = contains(keys(var.elastic_ip_allocation_ids), each.value.external_static_ip_key)
      error_message = "external_static_ip_key must exist in elastic_ip_allocation_ids (networking aws_external_static_ips.allocation_ids)."
    }
  }
}

resource "null_resource" "instance_local_exec" {
  for_each = {
    for k, v in local.instances : k => v
    if trimspace(try(v.local_exec.command, "")) != ""
  }

  provisioner "local-exec" {
    command = templatestring(each.value.local_exec.command, merge(
      try(each.value.local_exec.template_vars, {}),
      {
        # eip_association_id ties evaluation order after Elastic IP attach when external_static_ip_key is used (unused in templates).
        eip_association_id = contains(keys(aws_eip_association.static), each.key) ? aws_eip_association.static[each.key].id : ""
        public_ip          = aws_instance.this[each.key].public_ip
        private_ip         = aws_instance.this[each.key].private_ip
        nat_ip             = aws_instance.this[each.key].public_ip
        name               = try(each.value.name, each.key)
        region             = var.region
        instance_id        = aws_instance.this[each.key].id
      }
    ))
  }
}
