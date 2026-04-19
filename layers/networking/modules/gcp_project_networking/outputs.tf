output "project_id" {
  value = var.project_id
}

output "network_ids" {
  description = "VPC name => network id."
  value       = { for k, v in google_compute_network.this : k => v.id }
}

output "network_self_links" {
  description = "VPC name => network self link."
  value       = { for k, v in google_compute_network.this : k => v.self_link }
}

output "subnetwork_ids" {
  description = "Flattened subnet key => subnetwork id."
  value       = { for k, v in google_compute_subnetwork.this : k => v.id }
}

output "subnetwork_cidrs" {
  description = "Flattened subnet key => ip_cidr_range (same keys as subnetwork_ids)."
  value       = { for k, v in google_compute_subnetwork.this : k => v.ip_cidr_range }
}

output "cloud_nat_enabled" {
  description = "Whether Cloud NAT resources were requested (var.enable_cloud_nat)."
  value       = var.enable_cloud_nat
}

output "cloud_nat" {
  description = "Per vpc--region key: Cloud Router and Cloud NAT metadata for outbound internet without per-VM public IPs."
  value = var.enable_cloud_nat ? {
    for k, r in google_compute_router.nat : k => {
      vpc_name         = local.router_nat_instances[k].vpc_name
      region           = local.router_nat_instances[k].region
      router_name      = r.name
      router_self_link = r.self_link
      nat_name         = google_compute_router_nat.this[k].name
      nat_id           = google_compute_router_nat.this[k].id
    }
  } : {}
}
