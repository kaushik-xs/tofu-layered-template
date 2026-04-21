variable "tf_state_bucket" {
  description = "S3 bucket for remote state (same value as tofu init -backend-config=bucket=...; set in terraform.<AWS_PROFILE>.<workspace>.tfvars)."
  type        = string
}

variable "tf_state_key" {
  description = "S3 key prefix for remote state. scripts/tofu-layer-run.sh passes key=<this>/terraform_<AWS_PROFILE>.tfstate and empty workspace_key_prefix. Non-default workspaces use <workspace>/<key> in the bucket; workspace matches the second script argument."
  type        = string
}

variable "tf_state_region" {
  description = "AWS region of the state bucket (same as tofu init -backend-config=region=...)."
  type        = string
}

variable "tf_state_encrypt" {
  description = "Whether the state object is encrypted in S3 (same as tofu init -backend-config=encrypt=...)."
  type        = bool
}

variable "aws_region" {
  description = "AWS region used by this layer."
  type        = string
}

variable "gcp_project_id" {
  description = "GCP project ID used by this layer."
  type        = string
}

variable "gcp_region" {
  description = "GCP region used by this layer."
  type        = string
}

variable "gcp_enable_iap_ssh_firewall" {
  description = <<-EOT
    Default when network_topology.gcp.enable_iap_ssh_firewall is omitted: add a per-VPC firewall rule
    allowing IAP for TCP to SSH (35.235.240.0/20 -> tcp/22). Set false if you manage IAP SSH elsewhere.
  EOT
  type        = bool
  default     = true
}

variable "gcp_ssh_ingress_source_ranges" {
  description = <<-EOT
    Default when network_topology.gcp.ssh_ingress_source_ranges is omitted: optional CIDRs allowed for direct SSH
    (tcp/22) to VMs in each VPC. Empty means no extra rule (IAP-only unless you manage firewalls elsewhere).
  EOT
  type        = list(string)
  default     = []
}

variable "gcp_enable_cloud_nat" {
  description = <<-EOT
    Default when network_topology.gcp.enable_cloud_nat is omitted: create Cloud Router + Cloud NAT per VPC region
    so private VMs can reach the internet without an external IP.
  EOT
  type        = bool
  default     = true
}

variable "gcp_db_ingress_source_ranges" {
  description = <<-EOT
    Default when network_topology.gcp.db_ingress_source_ranges is omitted: CIDRs allowed to reach
    gcp_db_ingress_ports on VMs tagged with gcp_db_target_tags. Typically the public-subnet CIDR(s)
    hosting app VMs. Empty means no db ingress rule is created.
  EOT
  type        = list(string)
  default     = []
}

variable "gcp_db_ingress_ports" {
  description = <<-EOT
    Default when network_topology.gcp.db_ingress_ports is omitted: TCP ports opened by the db ingress rule.
    Only used when gcp_db_ingress_source_ranges is non-empty.
  EOT
  type        = list(string)
  default     = ["5432"]
}

variable "gcp_db_target_tags" {
  description = <<-EOT
    Default when network_topology.gcp.db_target_tags is omitted: network tags that identify DB VMs
    for the db ingress rule. Only used when gcp_db_ingress_source_ranges is non-empty.
  EOT
  type        = list(string)
  default     = ["db"]
}

variable "gcp_web_ingress_source_ranges" {
  description = <<-EOT
    Default when network_topology.gcp.web_ingress_source_ranges is omitted: CIDRs allowed to reach
    gcp_web_ingress_ports on all VMs. Use ["0.0.0.0/0"] for public HTTP/HTTPS. Empty = no rule.
  EOT
  type        = list(string)
  default     = []
}

variable "gcp_web_ingress_ports" {
  description = <<-EOT
    Default when network_topology.gcp.web_ingress_ports is omitted: TCP ports opened by the web ingress rule.
    Only used when gcp_web_ingress_source_ranges is non-empty.
  EOT
  type        = list(string)
  default     = ["80", "443"]
}

variable "network_topology" {
  description = <<-EOT
    Abstract multi-cloud network layout. When aws.enabled or gcp.enabled is true, the corresponding
    regions (AWS) or projects (GCP) map is expanded into VPC/VNet resources and tiered subnets.
    Azure is reserved for future use and ignored by this layer.
    Optional network_topology.gcp.enable_iap_ssh_firewall (bool): when true, create IAP SSH firewall rules
    on each VPC; when omitted, gcp_enable_iap_ssh_firewall at the root of this file is used.
    Optional network_topology.gcp.ssh_ingress_source_ranges (list): CIDRs for direct SSH to tcp/22; when omitted,
    gcp_ssh_ingress_source_ranges at the root of this file is used (default []).
    Optional network_topology.gcp.enable_cloud_nat (bool): when false, do not create Cloud NAT; when omitted,
    gcp_enable_cloud_nat at the root of this file is used (default true).
  EOT
  type        = any
  default     = {}
}

variable "external_static_ips" {
  description = <<-EOT
    Reserved public (static) addresses, separate from VPC topology in network_topology.
    AWS: Elastic IPs (non-ephemeral until released) under aws.regions.<region>.elastic_ips.
    GCP: regional external addresses (google_compute_address) and optional global external
    addresses (google_compute_global_address) under gcp.projects.<project_id>.
    Do not put firewall settings here: use network_topology.gcp.enable_iap_ssh_firewall and
    network_topology.gcp.ssh_ingress_source_ranges (or root gcp_* equivalents).
  EOT
  type        = any
  default     = {}
}
