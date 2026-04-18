variable "region" {
  description = "AWS region for this module instance (declared on the module provider)."
  type        = string
}

variable "vpcs" {
  description = "Map of VPC name => { cidr_block, optional tags, subnets = { tier_name = [ { name, cidr_block, availability_zone, type } ] } }."
  type        = map(any)
}
