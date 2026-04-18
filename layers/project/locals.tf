locals {
  networking_workspace_effective = trimspace(var.networking_workspace) != "" ? var.networking_workspace : terraform.workspace

  networking_remote_state_key = (
    trimspace(var.networking_tf_state_key) == "" ? "unused" : (
      local.networking_workspace_effective == "default"
      ? "${var.networking_tf_state_key}/terraform_${var.aws_profile}.tfstate"
      : "${local.networking_workspace_effective}/${var.networking_tf_state_key}/terraform_${var.aws_profile}.tfstate"
    )
  )

  aws_compute_instances  = try(var.compute_topology.aws.instances, {})
  gcp_compute_instances  = try(var.compute_topology.gcp.instances, {})
  compute_any_enabled    = try(var.compute_topology.aws.enabled, false) || try(var.compute_topology.gcp.enabled, false)
  networking_state_count = trimspace(var.networking_tf_state_key) != "" && local.compute_any_enabled ? 1 : 0

  aws_compute_enabled = (
    try(var.compute_topology.aws.enabled, false) &&
    (
      length(data.terraform_remote_state.networking) == 0 ? false :
      try(data.terraform_remote_state.networking[0].outputs.aws_networking, null) != null
    )
  )

  gcp_compute_enabled = (
    try(var.compute_topology.gcp.enabled, false) &&
    (
      length(data.terraform_remote_state.networking) == 0 ? false :
      try(data.terraform_remote_state.networking[0].outputs.gcp_networking, null) != null
    )
  )
}

check "networking_tf_state_when_compute_enabled" {
  assert {
    condition = (
      !local.compute_any_enabled ||
      trimspace(var.networking_tf_state_key) != ""
    )
    error_message = "When compute_topology.aws.enabled or compute_topology.gcp.enabled is true, networking_tf_state_key must be set (same tf_state_key prefix as the networking layer, before /terraform_<AWS_PROFILE>.tfstate)."
  }
}

check "networking_remote_state_loaded_when_compute_enabled" {
  assert {
    condition = (
      !local.compute_any_enabled ||
      local.networking_state_count > 0
    )
    error_message = "Networking remote state could not be configured. Set networking_tf_state_key and ensure compute is only enabled when state is available."
  }
}

check "aws_networking_when_aws_compute" {
  assert {
    condition = (
      !try(var.compute_topology.aws.enabled, false) ||
      length(local.aws_compute_instances) == 0 ||
      (
        length(data.terraform_remote_state.networking) > 0 &&
        try(data.terraform_remote_state.networking[0].outputs.aws_networking, null) != null
      )
    )
    error_message = "compute_topology.aws has instances but networking remote state has no aws_networking output. Enable AWS in the networking layer for this region or disable AWS compute."
  }
}

check "gcp_networking_when_gcp_compute" {
  assert {
    condition = (
      !try(var.compute_topology.gcp.enabled, false) ||
      length(local.gcp_compute_instances) == 0 ||
      (
        length(data.terraform_remote_state.networking) > 0 &&
        try(data.terraform_remote_state.networking[0].outputs.gcp_networking, null) != null
      )
    )
    error_message = "compute_topology.gcp has instances but networking remote state has no gcp_networking output. Enable GCP in the networking layer for this project or disable GCP compute."
  }
}

check "aws_subnet_keys_in_networking_state" {
  assert {
    condition = (
      local.aws_compute_enabled == false ? true : alltrue([
        for _, inst in local.aws_compute_instances : contains(
          keys(try(data.terraform_remote_state.networking[0].outputs.aws_networking.subnet_ids, {})),
          try(inst.subnet_key, "")
        )
      ])
    )
    error_message = "Each AWS compute instance must set subnet_key to a key from networking outputs (aws_networking.subnet_ids), e.g. core-public-public-a."
  }
}

check "gcp_subnet_keys_in_networking_state" {
  assert {
    condition = (
      local.gcp_compute_enabled == false ? true : alltrue([
        for _, inst in local.gcp_compute_instances : contains(
          keys(try(data.terraform_remote_state.networking[0].outputs.gcp_networking.subnetwork_ids, {})),
          try(inst.subnet_key, "")
        )
      ])
    )
    error_message = "Each GCP compute instance must set subnet_key to a key from networking outputs (gcp_networking.subnetwork_ids), e.g. qa-primary-private-qa-private-subnet."
  }
}
