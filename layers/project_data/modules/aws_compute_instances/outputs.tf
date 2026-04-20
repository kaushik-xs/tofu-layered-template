output "instance_ids" {
  description = "Logical name => EC2 instance id."
  value       = { for k, v in aws_instance.this : k => v.id }
}

output "private_ips" {
  description = "Logical name => primary private IPv4."
  value       = { for k, v in aws_instance.this : k => v.private_ip }
}

output "public_ips" {
  description = "Logical name => primary public IPv4 (Elastic IP after association when external_static_ip_key is set)."
  value       = { for k, v in aws_instance.this : k => try(v.public_ip, null) }
}

output "instances" {
  description = "List of instance objects: name, zone (availability_zone), ip (private), external_ip (public, null if none)."
  value = [
    for k, v in aws_instance.this : {
      name        = try(v.tags["Name"], k)
      zone        = v.availability_zone
      ip          = v.private_ip
      external_ip = try(v.public_ip, null)
    }
  ]
}
