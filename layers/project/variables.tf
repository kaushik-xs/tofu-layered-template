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

variable "aws_profile" {
  description = "AWS CLI profile name; must match AWS_PROFILE used with scripts/tofu-layer-run.sh. For project the script exports TF_VAR_aws_profile=$AWS_PROFILE (not set in tfvars). If you run tofu without the script, set TF_VAR_aws_profile to the same value as AWS_PROFILE."
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

variable "global_identity_workspace" {
  description = "OpenTofu workspace name whose state project should read for global_identity (must match the second argument to scripts/tofu-layer-run.sh for that layer; e.g. global)."
  type        = string
}

variable "global_identity_tf_state_key" {
  description = "tf_state_key from global_identity's terraform.<profile>.<workspace>.tfvars (path prefix before /terraform_<AWS_PROFILE>.tfstate; profile segment comes from the AWS_PROFILE env var, same as tofu-layer-run.sh)."
  type        = string
}

variable "route53_records" {
  description = "Route53 records grouped by hosted zone DNS name; zone_id comes from global_identity remote state. Same object shape as global_identity.route53_records. Do not repeat the same zone/name/type here as in global_identity (one Terraform stack per record set in AWS)."
  type = map(list(object({
    name    = string
    type    = string
    ttl     = optional(number, 300)
    records = list(string)
  })))
  default = {}
}

variable "networking_workspace" {
  description = "OpenTofu workspace whose remote state contains the networking layer outputs. When empty, terraform.workspace is used so project and networking align on the same workspace name (e.g. qa)."
  type        = string
  default     = ""
}

variable "networking_tf_state_key" {
  description = "tf_state_key from networking's terraform.<profile>.<workspace>.tfvars (prefix before /terraform_<AWS_PROFILE>.tfstate). Required when compute_topology.aws.enabled or compute_topology.gcp.enabled is true."
  type        = string
  default     = ""
}

variable "compute_topology" {
  description = <<-EOT
    Declarative VM layout for AWS and GCP. Subnet and network identifiers resolve from networking remote state
    (networking_tf_state_key). Each instance sets subnet_key to match networking outputs: aws_networking.subnet_ids
    or gcp_networking.subnetwork_ids (same flattened keys as the networking modules, e.g. core-public-public-a or
    qa-primary-private-qa-private-subnet). Optional vpc_name and network_name are applied as tags (AWS) or metadata (GCP).
    For addressing: set private_ip to a literal address, or set private_ip_host_index to compute the address with
    cidrhost() from networking outputs (aws_networking.subnet_cidrs / gcp_networking.subnetwork_cidrs). If both are
    omitted, the cloud assigns an address. Explicit private_ip wins when non-empty.
    Optional per-instance os: AWS uses amazon-linux-2023 (default) or ubuntu-server-lts (24.04 LTS); set ami_id to override.
    GCP uses debian-12 (default) or ubuntu-server-lts (24.04 LTS); set boot_disk_image to override.
    Optional external_static_ip_key: logical name of a reserved address from the networking layer
    (external_static_ips / Elastic IPs or GCP regional addresses). Must match a key in networking outputs
    aws_external_static_ips.allocation_ids or gcp_external_static_ips.regional_addresses.
    Optional per-instance local_exec.command: runs a local-exec provisioner after the VM exists (AWS: after Elastic IP
    association when used). Command is passed to templatestring with public_ip, nat_ip, private_ip, name, region,
    instance_id, and on GCP also zone. In .tfvars, escape Terraform string interpolation for template placeholders (see example tfvars).
  EOT
  type        = any
  default     = {}
}
