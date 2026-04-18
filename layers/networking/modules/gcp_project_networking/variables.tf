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

variable "enable_iap_ssh_firewall" {
  description = "When true, create an ingress firewall rule per VPC allowing TCP 22 from 35.235.240.0/20 (IAP for TCP). Required for SSH via Cloud IAP (e.g. gcloud compute ssh --tunnel-through-iap)."
  type        = bool
  default     = true
}
