output "aws_compute_instances" {
  description = "EC2 instances from computes when AWS compute is enabled and networking state exposes aws_networking."
  value = local.aws_compute_enabled ? {
    instance_ids = module.aws_compute[0].instance_ids
    private_ips  = module.aws_compute[0].private_ips
    public_ips   = module.aws_compute[0].public_ips
  } : null
}

output "aws_instances" {
  description = "AWS EC2 instances as a list of objects with name, zone, ip, and external_ip."
  value       = local.aws_compute_enabled ? module.aws_compute[0].instances : []
}

output "gcp_compute_instances" {
  description = "GCE instances from computes when GCP compute is enabled and networking state exposes gcp_networking."
  value = local.gcp_compute_enabled ? {
    instance_self_links = module.gcp_compute[0].instance_self_links
    instance_ids        = module.gcp_compute[0].instance_ids
    network_ips         = module.gcp_compute[0].network_ips
    public_ips          = module.gcp_compute[0].public_ips
    cloud_nat           = module.gcp_compute[0].cloud_nat
    cloud_nat_enabled   = module.gcp_compute[0].cloud_nat_enabled
  } : null
}

output "gcp_instances" {
  description = "GCP Compute Engine instances as a list of objects with name, zone, ip, and external_ip."
  value       = local.gcp_compute_enabled ? module.gcp_compute[0].instances : []
}
