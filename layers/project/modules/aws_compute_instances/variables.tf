variable "region" {
  description = "AWS region (passed through for documentation; provider is configured at root)."
  type        = string
}

variable "instances" {
  description = <<-EOT
    Map of logical name => instance settings. subnet_key must match a key in networking layer aws_networking.subnet_ids
    (same flattened key as the networking module: "<vpc>-<tier>-<subnet_name>").
    Optional: vpc_name / network_name (tags), private_ip (static address in subnet; may be pre-resolved from
    private_ip_host_index at the project root), ami_id, instance_type, security_group_ids (defaults to VPC default SG
    if empty), user_data, tags.
    Optional external_static_ip_key: logical name of an Elastic IP from networking outputs
    (aws_external_static_ips.allocation_ids); associates that EIP to this instance via aws_eip_association.
  EOT
  type        = map(any)
}

variable "subnet_ids" {
  description = "Flattened subnet key => subnet id from networking remote state (aws_networking.subnet_ids)."
  type        = map(string)
}

variable "elastic_ip_allocation_ids" {
  description = "Logical Elastic IP name => allocation id from networking (aws_external_static_ips.allocation_ids). Unused keys are ignored."
  type        = map(string)
  default     = {}
}
