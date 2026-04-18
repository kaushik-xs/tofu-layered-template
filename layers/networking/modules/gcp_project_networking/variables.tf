variable "project_id" {
  description = "GCP project ID for this module instance."
  type        = string
}

variable "default_region" {
  description = "Default region for the provider and for subnets that omit region."
  type        = string
}

variable "vpcs" {
  description = "Map of VPC name => { optional routing_mode, subnets = { tier = [ { name, cidr_block, optional region, optional private_access } ] } }."
  type        = map(any)
}
