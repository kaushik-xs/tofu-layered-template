output "network_topology_enabled" {
  description = "Which cloud blocks are enabled in var.network_topology."
  value = {
    aws = try(var.network_topology.aws.enabled, false)
    gcp = try(var.network_topology.gcp.enabled, false)
  }
}

output "aws_networking" {
  description = "VPC and subnet ids for var.aws_region when AWS topology is enabled and populated."
  value = local.aws_networking_enabled ? {
    region       = module.aws_networking[0].region
    vpc_ids      = module.aws_networking[0].vpc_ids
    subnet_ids   = module.aws_networking[0].subnet_ids
    subnet_cidrs = module.aws_networking[0].subnet_cidrs
  } : null
}

output "gcp_networking" {
  description = "VPC and subnet ids for var.gcp_project_id when GCP topology is enabled and populated."
  value = local.gcp_networking_enabled ? {
    project_id           = module.gcp_networking[0].project_id
    network_ids          = module.gcp_networking[0].network_ids
    network_self_links   = module.gcp_networking[0].network_self_links
    subnetwork_ids       = module.gcp_networking[0].subnetwork_ids
    subnetwork_cidrs     = module.gcp_networking[0].subnetwork_cidrs
  } : null
}
