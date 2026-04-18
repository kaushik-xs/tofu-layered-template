variable "region" {
  description = "AWS region (passed through for documentation; provider is configured at root)."
  type        = string
}

variable "instances" {
  description = <<-EOT
    Map of logical name => instance settings. subnet_key must match a key in networking layer aws_networking.subnet_ids
    (same flattened key as the networking module: "<vpc>-<tier>-<subnet_name>").
    Optional: vpc_name / network_name (tags), private_ip (static address in subnet; may be pre-resolved from
    private_ip_host_index at the project root), os (amazon-linux-2023 | ubuntu-server-lts), ami_id (overrides os),
    instance_type, security_group_ids (defaults to VPC default SG if empty), user_data, tags.
    ubuntu-server-lts resolves to Ubuntu Server 24.04 LTS (Noble) x86_64 in this region.
    Optional local_exec: run a local-exec provisioner after the instance exists and after any Elastic IP association.
    Set local_exec.command; templatestring supplies public_ip, nat_ip, private_ip, name, region, instance_id,
    ansible_user (ec2-user for amazon-linux-2023, ubuntu for ubuntu-server-lts; override with ansible_user on the instance),
    eip_association_id (empty when no static EIP), and optional local_exec.template_vars for extra template keys.
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
