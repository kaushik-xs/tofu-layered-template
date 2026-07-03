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

variable "aws_enable_nat_gateway" {
  description = <<-EOT
    Default when network_topology.aws.enable_nat_gateway is omitted: create one NAT gateway per VPC
    (in a public subnet) so private-subnet VMs can reach the internet without a public IP.
  EOT
  type        = bool
  default     = true
}

variable "aws_ssh_ingress_source_ranges" {
  description = <<-EOT
    Default when network_topology.aws.ssh_ingress_source_ranges is omitted: CIDRs allowed direct SSH
    (tcp/22) to the per-VPC AWS ssh security group. Per-VPC override via vpcs.<name>.ssh_ingress_source_ranges.
    Empty means the SG is created egress-only (no ssh ingress).
  EOT
  type        = list(string)
  default     = []
}

variable "aws_db_ingress_source_ranges" {
  description = <<-EOT
    Default when network_topology.aws.db_ingress_source_ranges is omitted: CIDRs allowed to reach the DB ports
    (aws_db_ports) on the per-VPC AWS ssh security group. Set to the VPC CIDR so app instances reach the DB instance
    on the same SG. Per-VPC override via vpcs.<name>.db_ingress_source_ranges. Empty = no DB ingress rule.
  EOT
  type        = list(string)
  default     = []
}

variable "aws_db_ports" {
  description = "Default when network_topology.aws.db_ports is omitted: TCP ports for the DB ingress rule (5432 PostgreSQL, 6379 Redis, 5672 AMQP/RabbitMQ)."
  type        = list(number)
  default     = [5432, 6379, 5672]
}

variable "aws_web_ingress_source_ranges" {
  description = <<-EOT
    Default when network_topology.aws.web_ingress_source_ranges is omitted: CIDRs allowed to reach the web ports
    (aws_web_ports) on the per-VPC AWS ssh security group. Use ["0.0.0.0/0"] for public HTTP/HTTPS so Caddy can
    serve traffic and Let's Encrypt ACME HTTP-01 (tcp/80) can validate. Per-VPC override via
    vpcs.<name>.web_ingress_source_ranges. Empty = no web ingress rule.
  EOT
  type        = list(string)
  default     = []
}

variable "aws_web_ports" {
  description = "Default when network_topology.aws.web_ports is omitted: TCP ports for the web ingress rule (80 HTTP / ACME HTTP-01, 443 HTTPS)."
  type        = list(number)
  default     = [80, 443]
}

variable "gcp_project_id" {
  description = "GCP project ID used by this layer."
  type        = string
  default     = null
}

variable "gcp_region" {
  description = "GCP region used by this layer."
  type        = string
  default     = null
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

variable "gcp_zerotier_ingress_source_ranges" {
  description = <<-EOT
    Default when network_topology.gcp.zerotier_ingress_source_ranges is omitted: CIDRs allowed to reach
    UDP 9993 on all VMs for ZeroTier peer traffic. Use ["0.0.0.0/0"] to allow all peers. Empty = no rule.
  EOT
  type        = list(string)
  default     = []
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
    Optional network_topology.aws.enable_nat_gateway (bool): when false, do not create AWS NAT gateways; when omitted,
    aws_enable_nat_gateway at the root of this file is used (default true).
  EOT
  type        = any
  default     = {}
}

variable "aws_compute_key_pair_name" {
  description = <<-EOT
    Name of the shared EC2 key pair generated in this layer and consumed by the project and project_data layers
    (bastion + private VMs use the same key so you can SSH the bastion and jump to private VMs). Must be unique per
    AWS account/region — include the workspace/environment in the value. Leave empty to create no key pair (e.g. a
    GCP-only deploy); when empty the aws_compute_key_pair_name / aws_compute_private_key_pem outputs are null.
  EOT
  type        = string
  default     = ""
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
