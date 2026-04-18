module "aws_networking" {
  count  = local.aws_networking_enabled ? 1 : 0
  source = "./modules/aws_region_networking"

  region = var.aws_region
  vpcs   = try(var.network_topology.aws.regions[var.aws_region].vpcs, {})
}
