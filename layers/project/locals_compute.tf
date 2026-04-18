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
      }
    )
  }
}
