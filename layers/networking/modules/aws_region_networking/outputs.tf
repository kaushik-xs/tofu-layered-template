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

output "ssh_security_group_ids" {
  description = "VPC name => ssh security group id."
  value       = { for k, v in aws_security_group.ssh : k => v.id }
}

output "subnet_vpc_names" {
  description = "Flattened subnet key => VPC name (same keys as subnet_ids)."
  value       = { for k, s in local.subnets_by_key : k => s.vpc_name }
}
