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
