variable "project_id" {
  description = "GCP project ID for this module instance."
  type        = string
}

variable "default_region" {
  description = "Default region when a regional address omits region."
  type        = string
}

variable "regional_external_addresses" {
  description = "Map of name => { region (optional), optional description, optional network_tier, optional ip_version }."
  type        = map(any)
  default     = {}
}

variable "global_external_addresses" {
  description = "Map of name => { optional description, optional ip_version } for global external IPv4/IPv6."
  type        = map(any)
  default     = {}
}
