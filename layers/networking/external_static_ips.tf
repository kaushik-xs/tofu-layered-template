module "aws_static_ips" {
  count  = local.aws_static_ips_enabled ? 1 : 0
  source = "./modules/aws_region_static_ips"

  region = var.aws_region
  elastic_ips = try(
    var.external_static_ips.aws.regions[var.aws_region].elastic_ips,
    {}
  )
}

module "gcp_static_ips" {
  count  = local.gcp_static_ips_enabled ? 1 : 0
  source = "./modules/gcp_project_static_ips"

  project_id = var.gcp_project_id
  default_region = try(
    var.external_static_ips.gcp.projects[var.gcp_project_id].region,
    var.gcp_region
  )
  regional_external_addresses = try(
    var.external_static_ips.gcp.projects[var.gcp_project_id].regional_external_addresses,
    {}
  )
  global_external_addresses = try(
    var.external_static_ips.gcp.projects[var.gcp_project_id].global_external_addresses,
    {}
  )
}
