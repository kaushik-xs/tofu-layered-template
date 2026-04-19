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

  # From networking: map key is "<vpc_name>--<region>" (same as gcp_networking.cloud_nat).
  gcp_networking_cloud_nat = (
    length(data.terraform_remote_state.networking) > 0 ?
    try(data.terraform_remote_state.networking[0].outputs.gcp_networking.cloud_nat, {}) :
    {}
  )

  gcp_nat_lookup_key_by_instance = {
    for name, inst in local.gcp_compute_instances : name => (
      try(inst.vpc_name, null) != null && trimspace(tostring(inst.vpc_name)) != "" ?
      "${trimspace(tostring(inst.vpc_name))}--${try(regex("^(.+)-[a-z]$", try(inst.zone, "${var.gcp_region}-a"))[0], var.gcp_region)}" :
      ""
    )
  }

  gcp_nat_metadata_by_instance = {
    for name, k in local.gcp_nat_lookup_key_by_instance : name => (
      k != "" && contains(keys(local.gcp_networking_cloud_nat), k) ? {
        "cloud-nat-lookup-key" = k
        "cloud-nat-router"     = local.gcp_networking_cloud_nat[k].router_name
        "cloud-nat-name"       = local.gcp_networking_cloud_nat[k].nat_name
        "cloud-nat-region"     = local.gcp_networking_cloud_nat[k].region
      } : {}
    )
  }

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
          try(local.gcp_nat_metadata_by_instance[name], {}),
          try(inst.metadata, {}),
        )
      }
    )
  }
}
