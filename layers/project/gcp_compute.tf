module "gcp_compute" {
  count  = local.gcp_compute_enabled ? 1 : 0
  source = "./modules/gcp_compute_instances"

  project_id     = var.gcp_project_id
  default_zone   = "${var.gcp_region}-a"
  instances      = local.gcp_compute_instances
  subnetwork_ids = data.terraform_remote_state.networking[0].outputs.gcp_networking.subnetwork_ids
}
