output "project_id" {
  value = var.project_id
}

output "regional_address_ids" {
  description = "Regional external address name => resource id."
  value       = { for k, v in google_compute_address.regional_external : k => v.id }
}

output "regional_addresses" {
  description = "Regional external address name => reserved IP (string)."
  value       = { for k, v in google_compute_address.regional_external : k => v.address }
}

output "regional_self_links" {
  description = "Regional external address name => self link."
  value       = { for k, v in google_compute_address.regional_external : k => v.self_link }
}

output "global_address_ids" {
  description = "Global external address name => resource id."
  value       = { for k, v in google_compute_global_address.global_external : k => v.id }
}

output "global_addresses" {
  description = "Global external address name => reserved IP (string)."
  value       = { for k, v in google_compute_global_address.global_external : k => v.address }
}

output "global_self_links" {
  description = "Global external address name => self link."
  value       = { for k, v in google_compute_global_address.global_external : k => v.self_link }
}
