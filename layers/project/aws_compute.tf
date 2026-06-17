module "aws_compute" {
  count  = local.aws_compute_enabled ? 1 : 0
  source = "./modules/aws_compute_instances"

  region                 = var.aws_region
  instances              = local.aws_compute_instances_effective
  ubuntu_ami_name_filter = var.aws_ubuntu_ami_name_filter
  subnet_ids             = data.terraform_remote_state.networking[0].outputs.aws_networking.subnet_ids

  # Managed SSH key pair so instances authenticate at first boot. Name is workspace+layer scoped to stay unique per account/region.
  ssh_public_key_path = var.aws_compute_ssh_public_key_path
  key_pair_name       = "${terraform.workspace}-project-compute"

  elastic_ip_allocation_ids = try(
    data.terraform_remote_state.networking[0].outputs.aws_external_static_ips.allocation_ids,
    {}
  )
}
