locals {
  instances = var.instances

  instances_with_static_eip = {
    for k, v in local.instances : k => v
    if try(v.external_static_ip_key, null) != null && trimspace(tostring(v.external_static_ip_key)) != ""
  }

  # Per-instance Ubuntu AMI name filter, falling back to the module default. Deduped to a set so
  # instances sharing a filter share a single data.aws_ami lookup. Only instances that resolve their
  # AMI through the Ubuntu lookup (os = ubuntu-server-lts, no ami_id override) are included.
  ubuntu_ami_name_filters = toset([
    for _, v in local.instances : try(v.ubuntu_ami_name_filter, var.ubuntu_ami_name_filter)
    if try(v.os, "amazon-linux-2023") == "ubuntu-server-lts" && (try(v.ami_id, null) == null || trimspace(tostring(v.ami_id)) == "")
  ])
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

# Ubuntu Server 26.04 LTS (Resolute); update the name filter (module default or per-instance) for a different release.
# Keyed by the name filter string so instances sharing a filter reuse one lookup.
data "aws_ami" "ubuntu_lts" {
  for_each    = local.ubuntu_ami_name_filters
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = [each.value]
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

# Managed key pair from a public key on disk. Created only when ssh_public_key_path is set; attached to every
# instance below via key_name so SSH/ansible authenticate at first boot. key_pair_name must be unique per region/account.
resource "aws_key_pair" "this" {
  count = trimspace(var.ssh_public_key_path) != "" ? 1 : 0

  key_name   = var.key_pair_name
  public_key = chomp(file(pathexpand(var.ssh_public_key_path)))
}

resource "aws_instance" "this" {
  for_each = local.instances

  ami = coalesce(
    try(each.value.ami_id, null) != null && trimspace(tostring(each.value.ami_id)) != "" ? each.value.ami_id : null,
    try(each.value.os, "amazon-linux-2023") == "ubuntu-server-lts" ? data.aws_ami.ubuntu_lts[try(each.value.ubuntu_ami_name_filter, var.ubuntu_ami_name_filter)].id : data.aws_ami.amazon_linux_2023[0].id
  )
  instance_type = try(each.value.instance_type, "t3.micro")
  subnet_id     = data.aws_subnet.instance[each.key].id

  private_ip = try(each.value.private_ip, null)

  # Per-instance key_name wins; otherwise the module-managed key pair (when ssh_public_key_path is set); else none.
  key_name = (
    try(each.value.key_name, null) != null && trimspace(tostring(each.value.key_name)) != "" ?
    each.value.key_name :
    (length(aws_key_pair.this) > 0 ? aws_key_pair.this[0].key_name : null)
  )

  vpc_security_group_ids = length(try(each.value.security_group_ids, [])) > 0 ? each.value.security_group_ids : [data.aws_security_group.vpc_default[each.key].id]

  user_data = try(each.value.user_data, null)

  root_block_device {
    volume_size = try(each.value.root_volume_size_gb, 20)
    volume_type = try(each.value.root_volume_type, "gp3")
  }

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
    # Run from the layer root so paths like ../../playbooks match terraform.tfvars examples.
    working_dir = path.root

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
        ansible_user = (
          try(each.value.ansible_user, null) != null && trimspace(tostring(each.value.ansible_user)) != "" ?
          trimspace(tostring(each.value.ansible_user)) :
          try(each.value.os, "amazon-linux-2023") == "ubuntu-server-lts" ? "ubuntu" : "ec2-user"
        )
      }
    ))
  }
}
