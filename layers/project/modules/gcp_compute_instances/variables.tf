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
    Optional: vpc_name / network_name (metadata), private_ip (alias network_ip), machine_type, zone, boot_disk_image,
    service_account (email), metadata, labels.
  EOT
  type        = map(any)
}

variable "subnetwork_ids" {
  description = "Flattened subnet key => subnetwork id from networking remote state (gcp_networking.subnetwork_ids)."
  type        = map(string)
}
