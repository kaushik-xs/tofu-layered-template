output "instance_ids" {
  description = "Logical name => EC2 instance id."
  value       = { for k, v in aws_instance.this : k => v.id }
}

output "private_ips" {
  description = "Logical name => primary private IPv4."
  value       = { for k, v in aws_instance.this : k => v.private_ip }
}
