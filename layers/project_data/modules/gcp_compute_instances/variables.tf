variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region (used for local_exec template variable region)."
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
    project root), os (debian-12 | ubuntu-server-lts), boot_disk_image (overrides os), machine_type, zone,
    service_account (email), metadata, labels.
    ubuntu-server-lts uses the ubuntu-2404-lts-amd64 image family (Ubuntu Server 24.04 LTS).
    Optional local_exec: run a local-exec provisioner after the instance exists (null_resource). Set local_exec.command
    to a shell script; templatestring supplies public_ip, nat_ip, private_ip, name, zone, region, instance_id,
    ansible_user (ubuntu for ubuntu-server-lts, debian for debian-12; override with ansible_user on the instance). Optional
    local_exec.template_vars merges extra name => value pairs into the template map. In .tfvars, escape brace placeholders
    for templatestring (dollar-dollar before the opening brace).
    Optional tags: list of GCP network tags (strings) applied to the instance — used to scope firewall rules
    (e.g. ["db"] to receive the db_ingress firewall rule from the networking layer).
    Optional external_static_ip_key: logical name of a regional reserved address from networking
    (gcp_external_static_ips.regional_addresses); sets access_config.nat_ip to that IPv4 (API requires the address string, not a resource URL).
    When local_exec is set, templatestring also receives instance_region, cloud_nat, cloud_nat_enabled, cloud_nat_lookup_key,
    and cloud_nat_for_instance (the latter two when vpc_name is set; matches networking cloud_nat key "<vpc_name>--<region>").
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

variable "cloud_nat" {
  description = "gcp_networking.cloud_nat from networking remote state (vpc--region => router/nat metadata)."
  type        = map(any)
  default     = {}
}

variable "cloud_nat_enabled" {
  description = "gcp_networking.cloud_nat_enabled from networking remote state."
  type        = bool
  default     = false
}
