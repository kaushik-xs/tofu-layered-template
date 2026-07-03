module "aws_compute" {
  count  = local.aws_compute_enabled ? 1 : 0
  source = "./modules/aws_compute_instances"

  region                       = var.aws_region
  instances                    = local.aws_compute_instances_effective
  ubuntu_ami_name_filter       = var.aws_ubuntu_ami_name_filter
  amazon_linux_ami_name_filter = var.aws_amazon_linux_ami_name_filter
  subnet_ids                   = data.terraform_remote_state.networking[0].outputs.aws_networking.subnet_ids

  # Shared SSH key pair from the networking layer. Bastion (here) and private VMs (project_data) use the same key,
  # so you SSH the bastion then jump to the private VMs. A per-instance key_name in computes.aws.instances still overrides.
  key_name = data.terraform_remote_state.networking[0].outputs.aws_compute_key_pair_name

  elastic_ip_allocation_ids = try(
    data.terraform_remote_state.networking[0].outputs.aws_external_static_ips.allocation_ids,
    {}
  )
}
