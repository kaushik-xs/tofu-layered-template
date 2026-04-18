module "aws_compute" {
  count  = local.aws_compute_enabled ? 1 : 0
  source = "./modules/aws_compute_instances"

  region     = var.aws_region
  instances  = local.aws_compute_instances_effective
  subnet_ids = data.terraform_remote_state.networking[0].outputs.aws_networking.subnet_ids

  elastic_ip_allocation_ids = try(
    data.terraform_remote_state.networking[0].outputs.aws_external_static_ips.allocation_ids,
    {}
  )
}
