output "region" {
  value = var.region
}

output "vpc_ids" {
  description = "VPC name => id."
  value       = { for k, v in aws_vpc.this : k => v.id }
}

output "subnet_ids" {
  description = "Flattened subnet key => id."
  value       = { for k, v in aws_subnet.this : k => v.id }
}
