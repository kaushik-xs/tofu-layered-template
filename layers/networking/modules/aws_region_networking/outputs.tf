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

output "subnet_cidrs" {
  description = "Flattened subnet key => CIDR block (same keys as subnet_ids)."
  value       = { for k, v in aws_subnet.this : k => v.cidr_block }
}

output "nat_gateway_enabled" {
  description = "Whether NAT gateways were requested (var.enable_nat_gateway)."
  value       = var.enable_nat_gateway
}

output "nat_gateways" {
  description = "VPC name => NAT gateway metadata (id, public IP, host subnet) for private-subnet outbound internet."
  value = {
    for k, n in aws_nat_gateway.this : k => {
      id        = n.id
      public_ip = aws_eip.nat[k].public_ip
      subnet_id = n.subnet_id
    }
  }
}
