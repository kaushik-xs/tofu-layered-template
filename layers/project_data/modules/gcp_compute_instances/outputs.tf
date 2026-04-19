output "instance_self_links" {
  description = "Logical name => instance self link."
  value       = { for k, v in google_compute_instance.this : k => v.self_link }
}

output "instance_ids" {
  description = "Logical name => instance id."
  value       = { for k, v in google_compute_instance.this : k => v.instance_id }
}

output "network_ips" {
  description = "Logical name => primary internal IP from the first network interface."
  value       = { for k, v in google_compute_instance.this : k => v.network_interface[0].network_ip }
}

output "public_ips" {
  description = "Logical name => reserved external NAT IP when external_static_ip_key is set, else null."
  value = {
    for k, v in google_compute_instance.this : k => try(v.network_interface[0].access_config[0].nat_ip, null)
  }
}
