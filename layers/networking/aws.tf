module "aws_networking" {
  count  = local.aws_networking_enabled ? 1 : 0
  source = "./modules/aws_region_networking"

  region             = var.aws_region
  vpcs               = try(var.network_topology.aws.regions[var.aws_region].vpcs, {})
  enable_nat_gateway = try(var.network_topology.aws.enable_nat_gateway, var.aws_enable_nat_gateway)

  ssh_ingress_source_ranges = try(var.network_topology.aws.ssh_ingress_source_ranges, var.aws_ssh_ingress_source_ranges)
  db_ingress_source_ranges  = try(var.network_topology.aws.db_ingress_source_ranges, var.aws_db_ingress_source_ranges)
  db_ports                  = try(var.network_topology.aws.db_ports, var.aws_db_ports)
  web_ingress_source_ranges = try(var.network_topology.aws.web_ingress_source_ranges, var.aws_web_ingress_source_ranges)
  web_ports                 = try(var.network_topology.aws.web_ports, var.aws_web_ports)
}
