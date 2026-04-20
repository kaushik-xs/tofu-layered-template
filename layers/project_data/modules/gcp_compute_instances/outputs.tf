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

output "cloud_nat" {
  description = "Passthrough of networking Cloud NAT metadata (same as module input cloud_nat)."
  value       = var.cloud_nat
}

output "cloud_nat_enabled" {
  description = "Passthrough of networking cloud_nat_enabled flag."
  value       = var.cloud_nat_enabled
}

output "instances" {
  description = "List of instance objects: name, zone, ip (internal), external_ip (NAT IP, null if none)."
  value = [
    for k, v in google_compute_instance.this : {
      name        = v.name
      zone        = v.zone
      ip          = v.network_interface[0].network_ip
      external_ip = try(v.network_interface[0].access_config[0].nat_ip, null)
    }
  ]
}
