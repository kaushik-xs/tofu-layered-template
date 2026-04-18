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
