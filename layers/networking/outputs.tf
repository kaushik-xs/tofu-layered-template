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
    project_id         = module.gcp_networking[0].project_id
    network_ids        = module.gcp_networking[0].network_ids
    network_self_links = module.gcp_networking[0].network_self_links
    subnetwork_ids     = module.gcp_networking[0].subnetwork_ids
    subnetwork_cidrs   = module.gcp_networking[0].subnetwork_cidrs
  } : null
}

output "external_static_ips" {
  description = "Logical name => reserved public address string per cloud (AWS Elastic IPs; GCP regional and global external addresses)."
  value = {
    aws = local.aws_static_ips_enabled ? module.aws_static_ips[0].public_ips : null
    gcp = local.gcp_static_ips_enabled ? {
      regional = module.gcp_static_ips[0].regional_addresses
      global   = module.gcp_static_ips[0].global_addresses
    } : null
  }
}

output "external_static_ips_enabled" {
  description = "Which cloud blocks are enabled in var.external_static_ips."
  value = {
    aws = try(var.external_static_ips.aws.enabled, false)
    gcp = try(var.external_static_ips.gcp.enabled, false)
  }
}

output "aws_external_static_ips" {
  description = "Elastic IP allocation and public addresses for var.aws_region when external_static_ips.aws is enabled."
  value = local.aws_static_ips_enabled ? {
    region          = module.aws_static_ips[0].region
    allocation_ids  = module.aws_static_ips[0].allocation_ids
    public_ips      = module.aws_static_ips[0].public_ips
    association_ids = module.aws_static_ips[0].association_ids
  } : null
}

output "gcp_external_static_ips" {
  description = "Reserved regional and global external addresses for var.gcp_project_id when external_static_ips.gcp is enabled."
  value = local.gcp_static_ips_enabled ? {
    project_id           = module.gcp_static_ips[0].project_id
    regional_address_ids = module.gcp_static_ips[0].regional_address_ids
    regional_addresses   = module.gcp_static_ips[0].regional_addresses
    regional_self_links  = module.gcp_static_ips[0].regional_self_links
    global_address_ids   = module.gcp_static_ips[0].global_address_ids
    global_addresses     = module.gcp_static_ips[0].global_addresses
    global_self_links    = module.gcp_static_ips[0].global_self_links
  } : null
}
