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
    Optional root_volume_size_gb (root EBS size in GiB, default 20) and root_volume_type (default gp3).
    ubuntu-server-lts resolves to Ubuntu Server 26.04 LTS (Resolute) x86_64 in this region.
    Optional ubuntu_ami_name_filter: per-instance override of the AMI name filter used for ubuntu-server-lts
    (defaults to var.ubuntu_ami_name_filter); ignored unless os = ubuntu-server-lts and ami_id is unset.
    Optional local_exec: run a local-exec provisioner after the instance exists and after any Elastic IP association.
    Set local_exec.command; templatestring supplies public_ip, nat_ip, private_ip, name, region, instance_id,
    ansible_user (ec2-user for amazon-linux-2023, ubuntu for ubuntu-server-lts; override with ansible_user on the instance),
    eip_association_id (empty when no static EIP), and optional local_exec.template_vars for extra template keys.
    Optional external_static_ip_key: logical name of an Elastic IP from networking outputs
    (aws_external_static_ips.allocation_ids); associates that EIP to this instance via aws_eip_association.
  EOT
  type        = map(any)
}

variable "ubuntu_ami_name_filter" {
  description = "Name filter for the Ubuntu LTS AMI lookup (data.aws_ami). Canonical publishes Resolute under the hvm-ssd-gp3 path; wildcard matches both old and new layouts."
  type        = string
  default     = "ubuntu/images/hvm-ssd*/ubuntu-resolute-26.04-amd64-server-*"
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

variable "ssh_public_key_path" {
  description = <<-EOT
    Optional path to an SSH *public* key file (e.g. ~/.ssh/id_rsa.pub). When set, a managed aws_key_pair is created
    from it and attached to every instance via key_name, so SSH (and the ansible local_exec provisioner) works at
    first boot. The matching private key is what you pass to scripts/ssh-ec2.sh. A per-instance key_name overrides
    this. When empty, no key pair is attached unless an instance sets its own key_name.
  EOT
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = <<-EOT
    Name for the managed aws_key_pair created from ssh_public_key_path. Must be unique per region/account, so include
    the workspace and layer in the name to avoid collisions across workspaces. Ignored when ssh_public_key_path is empty.
  EOT
  type        = string
  default     = ""
}
