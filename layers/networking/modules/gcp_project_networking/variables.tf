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
