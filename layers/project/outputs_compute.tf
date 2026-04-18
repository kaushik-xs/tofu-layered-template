output "aws_compute_instances" {
  description = "EC2 instances from compute_topology when AWS compute is enabled and networking state exposes aws_networking."
  value = local.aws_compute_enabled ? {
    instance_ids = module.aws_compute[0].instance_ids
    private_ips  = module.aws_compute[0].private_ips
    public_ips   = module.aws_compute[0].public_ips
  } : null
}

output "gcp_compute_instances" {
  description = "GCE instances from compute_topology when GCP compute is enabled and networking state exposes gcp_networking."
  value = local.gcp_compute_enabled ? {
    instance_self_links = module.gcp_compute[0].instance_self_links
    instance_ids        = module.gcp_compute[0].instance_ids
    network_ips         = module.gcp_compute[0].network_ips
    public_ips          = module.gcp_compute[0].public_ips
  } : null
}
