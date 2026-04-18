variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "default_zone" {
  description = "Zone used when an instance omits zone (e.g. asia-south1-a)."
  type        = string
}

variable "instances" {
  description = <<-EOT
    Map of logical name => instance settings. subnet_key must match a key in networking layer gcp_networking.subnetwork_ids
    (same flattened key as the networking module: "<vpc>-<tier>-<subnet_name>").
    Optional: vpc_name / network_name (metadata), private_ip (may be pre-resolved from private_ip_host_index at the
    project root), machine_type, zone, boot_disk_image, service_account (email), metadata, labels.
    Optional external_static_ip_key: logical name of a regional reserved address from networking
    (gcp_external_static_ips.regional_addresses); sets access_config.nat_ip to that IPv4 (API requires the address string, not a resource URL).
  EOT
  type        = map(any)
}

variable "subnetwork_ids" {
  description = "Flattened subnet key => subnetwork id from networking remote state (gcp_networking.subnetwork_ids)."
  type        = map(string)
}

variable "regional_external_addresses" {
  description = "Logical address name => reserved IPv4 from networking (gcp_external_static_ips.regional_addresses). Unused keys are ignored."
  type        = map(string)
  default     = {}
}
