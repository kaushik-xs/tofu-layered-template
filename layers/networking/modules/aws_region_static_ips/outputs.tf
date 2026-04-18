output "region" {
  value = var.region
}

output "allocation_ids" {
  description = "Elastic IP name => allocation id (eipalloc-...)."
  value       = { for k, v in aws_eip.this : k => v.id }
}

output "public_ips" {
  description = "Elastic IP name => public IPv4 address."
  value       = { for k, v in aws_eip.this : k => v.public_ip }
}

output "association_ids" {
  description = "Elastic IP name => association id when associated with an ENI, else null."
  value       = { for k, v in aws_eip.this : k => v.association_id }
}
