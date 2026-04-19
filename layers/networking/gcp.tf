module "gcp_networking" {
  count  = local.gcp_networking_enabled ? 1 : 0
  source = "./modules/gcp_project_networking"

  project_id                = var.gcp_project_id
  default_region            = try(var.network_topology.gcp.projects[var.gcp_project_id].region, var.gcp_region)
  vpcs                      = try(var.network_topology.gcp.projects[var.gcp_project_id].vpcs, {})
  enable_iap_ssh_firewall        = try(var.network_topology.gcp.enable_iap_ssh_firewall, var.gcp_enable_iap_ssh_firewall)
  ssh_ingress_source_ranges      = try(var.network_topology.gcp.ssh_ingress_source_ranges, var.gcp_ssh_ingress_source_ranges)
  enable_cloud_nat               = try(var.network_topology.gcp.enable_cloud_nat, var.gcp_enable_cloud_nat)
  db_ingress_source_ranges = try(var.network_topology.gcp.db_ingress_source_ranges, var.gcp_db_ingress_source_ranges)
  db_ingress_ports         = try(var.network_topology.gcp.db_ingress_ports, var.gcp_db_ingress_ports)
  db_target_tags           = try(var.network_topology.gcp.db_target_tags, var.gcp_db_target_tags)
}
