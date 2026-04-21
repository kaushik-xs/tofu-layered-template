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

variable "ssh_ingress_source_ranges" {
  description = <<-EOT
    When non-empty, create an additional per-VPC rule allowing TCP 22 from these CIDRs (direct SSH).
    Traffic to the VM public IP comes from your client address, not 35.235.240.0/20, so Ansible or ssh user@PUBLIC_IP
    needs this unless you use IAP tunneling (ProxyCommand) instead.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_cloud_nat" {
  description = "When true, create a Cloud Router and Cloud NAT per (VPC, region) so VMs without external IPs can use outbound internet (NAT egress)."
  type        = bool
  default     = true
}

variable "db_ingress_source_ranges" {
  description = <<-EOT
    When non-empty, create a per-VPC ingress rule allowing db_ingress_ports from these CIDRs to VMs
    carrying the tags in db_target_tags. Typical value: the public-subnet CIDR(s) where app VMs live,
    e.g. ["10.0.1.0/24"]. Leave empty to skip the rule entirely.
  EOT
  type        = list(string)
  default     = []
}

variable "db_ingress_ports" {
  description = <<-EOT
    TCP ports opened by the db ingress firewall rule. Extend this list as needed for additional database
    engines (e.g. ["5432", "3306", "5433"]). Only evaluated when db_ingress_source_ranges is non-empty.
  EOT
  type        = list(string)
  default     = ["5432"]
}

variable "db_target_tags" {
  description = <<-EOT
    Network tags applied to DB VMs that should receive the db ingress rule. Only evaluated when
    db_ingress_source_ranges is non-empty. Ensure your DB instances carry at least one of these tags
    (set via the tags field in the gcp_compute_instances module). Default: ["db"].
  EOT
  type        = list(string)
  default     = ["db"]
}

variable "web_ingress_source_ranges" {
  description = <<-EOT
    When non-empty, create a per-VPC ingress rule allowing web_ingress_ports from these CIDRs.
    Use ["0.0.0.0/0"] for public HTTP/HTTPS access. Leave empty to skip the rule.
  EOT
  type        = list(string)
  default     = []
}

variable "web_ingress_ports" {
  description = "TCP ports opened by the web ingress firewall rule. Only evaluated when web_ingress_source_ranges is non-empty."
  type        = list(string)
  default     = ["80", "443"]
}
