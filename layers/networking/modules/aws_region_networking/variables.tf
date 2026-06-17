variable "region" {
  description = "AWS region for this module instance (declared on the module provider)."
  type        = string
}

variable "vpcs" {
  description = "Map of VPC name => { cidr_block, optional tags, subnets = { tier_name = [ { name, cidr_block, availability_zone, type } ] } }."
  type        = map(any)
}

variable "enable_nat_gateway" {
  description = "When true, create one NAT gateway (with an Elastic IP) per VPC that has both a public and a private subnet, and route the private subnets' default traffic through it so private VMs get outbound internet."
  type        = bool
  default     = true
}

variable "ssh_ingress_source_ranges" {
  description = <<-EOT
    Default CIDRs allowed to reach tcp/22 on the per-VPC ssh security group.
    Per-VPC override: set ssh_ingress_source_ranges inside a vpcs entry.
    Empty list (and no per-VPC override) = SG created with egress-only, no ssh ingress.
  EOT
  type        = list(string)
  default     = []
}
