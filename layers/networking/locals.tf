locals {
  aws_networking_enabled = (
    try(var.network_topology.aws.enabled, false) &&
    contains(keys(try(var.network_topology.aws.regions, {})), var.aws_region)
  )

  gcp_networking_enabled = (
    try(var.network_topology.gcp.enabled, false) &&
    contains(keys(try(var.network_topology.gcp.projects, {})), var.gcp_project_id)
  )
}

check "aws_region_defined_when_aws_enabled" {
  assert {
    condition = (
      !try(var.network_topology.aws.enabled, false) ||
      contains(keys(try(var.network_topology.aws.regions, {})), var.aws_region)
    )
    error_message = "When network_topology.aws.enabled is true, network_topology.aws.regions must include the layer aws_region (${var.aws_region})."
  }
}

check "gcp_project_defined_when_gcp_enabled" {
  assert {
    condition = (
      !try(var.network_topology.gcp.enabled, false) ||
      contains(keys(try(var.network_topology.gcp.projects, {})), var.gcp_project_id)
    )
    error_message = "When network_topology.gcp.enabled is true, network_topology.gcp.projects must include the layer gcp_project_id (${var.gcp_project_id})."
  }
}
