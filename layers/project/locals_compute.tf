locals {
  networking_aws_subnet_cidrs = (
    length(data.terraform_remote_state.networking) > 0 ?
    try(data.terraform_remote_state.networking[0].outputs.aws_networking.subnet_cidrs, {}) :
    {}
  )

  networking_gcp_subnetwork_cidrs = (
    length(data.terraform_remote_state.networking) > 0 ?
    try(data.terraform_remote_state.networking[0].outputs.gcp_networking.subnetwork_cidrs, {}) :
    {}
  )

  # Per-VPC ssh security group ids and subnet_key => VPC name, from networking state.
  # Used to attach the ssh SG to instances that set ssh_sg = true.
  networking_aws_ssh_sg_ids = (
    length(data.terraform_remote_state.networking) > 0 ?
    try(data.terraform_remote_state.networking[0].outputs.aws_networking.ssh_security_group_ids, {}) :
    {}
  )

  networking_aws_subnet_vpc_names = (
    length(data.terraform_remote_state.networking) > 0 ?
    try(data.terraform_remote_state.networking[0].outputs.aws_networking.subnet_vpc_names, {}) :
    {}
  )

  aws_compute_instances_effective = {
    for name, inst in local.aws_compute_instances : name => merge(
      inst,
      {
        private_ip = (
          try(inst.private_ip, null) != null && trimspace(tostring(inst.private_ip)) != "" ? trimspace(tostring(inst.private_ip)) :
          try(inst.private_ip_host_index, null) != null && contains(keys(local.networking_aws_subnet_cidrs), try(inst.subnet_key, "")) ? cidrhost(
            local.networking_aws_subnet_cidrs[inst.subnet_key],
            inst.private_ip_host_index
          ) :
          null
        )
        # When ssh_sg = true, attach the ssh SG of the instance's VPC (resolved from subnet_key).
        # Any explicit security_group_ids are preserved and merged. When this list is non-empty the
        # compute module uses it instead of the VPC default SG.
        security_group_ids = concat(
          try(inst.security_group_ids, []),
          try(inst.ssh_sg, false) && contains(keys(local.networking_aws_subnet_vpc_names), try(inst.subnet_key, "")) ?
          compact([try(local.networking_aws_ssh_sg_ids[local.networking_aws_subnet_vpc_names[inst.subnet_key]], null)]) :
          []
        )
      }
    )
  }

  gcp_compute_instances_effective = {
    for name, inst in local.gcp_compute_instances : name => merge(
      inst,
      {
        private_ip = (
          try(inst.private_ip, null) != null && trimspace(tostring(inst.private_ip)) != "" ? trimspace(tostring(inst.private_ip)) :
          try(inst.private_ip_host_index, null) != null && contains(keys(local.networking_gcp_subnetwork_cidrs), try(inst.subnet_key, "")) ? cidrhost(
            local.networking_gcp_subnetwork_cidrs[inst.subnet_key],
            inst.private_ip_host_index
          ) :
          null
        )
        metadata = merge(
          trimspace(var.gcp_compute_ssh_public_key_path) == "" ? {} : {
            ssh-keys = "${try(inst.os, "debian-12") == "ubuntu-server-lts" ? "ubuntu" : "debian"}:${chomp(file(pathexpand(var.gcp_compute_ssh_public_key_path)))}"
          },
          try(inst.metadata, {}),
        )
      }
    )
  }
}
