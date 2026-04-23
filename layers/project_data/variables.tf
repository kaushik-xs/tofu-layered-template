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
  description = "AWS CLI profile name; must match AWS_PROFILE used with scripts/tofu-layer-run.sh. For project_data the script exports TF_VAR_aws_profile=$AWS_PROFILE (not set in tfvars). If you run tofu without the script, set TF_VAR_aws_profile to the same value as AWS_PROFILE."
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

variable "gcp_compute_ssh_public_key_path" {
  description = <<-EOT
    Optional path to an SSH *public* key file (e.g. ~/.ssh/id_rsa.pub) whose matching private key is used with
    ansible-playbook. The public key is merged into each GCP instance metadata as ssh-keys (ubuntu or debian user),
    so the VM authorizes SSH before local_exec runs. If empty, add keys via instance metadata, project ssh-keys, or OS Login.
  EOT
  type        = string
  default     = ""
}

variable "global_identity_workspace" {
  description = "OpenTofu workspace name whose state project_data should read for global_identity (must match the second argument to scripts/tofu-layer-run.sh for that layer; e.g. global)."
  type        = string
}

variable "global_identity_tf_state_key" {
  description = "tf_state_key from global_identity's terraform.<profile>.<workspace>.tfvars (path prefix before /terraform_<AWS_PROFILE>.tfstate; profile segment comes from the AWS_PROFILE env var, same as tofu-layer-run.sh)."
  type        = string
}

variable "networking_workspace" {
  description = "OpenTofu workspace whose remote state contains the networking layer outputs. When empty, terraform.workspace is used so project_data and networking align on the same workspace name (e.g. qa)."
  type        = string
  default     = ""
}

variable "networking_tf_state_key" {
  description = "tf_state_key from networking's terraform.<profile>.<workspace>.tfvars (prefix before /terraform_<AWS_PROFILE>.tfstate). Required when computes.aws.enabled or computes.gcp.enabled is true."
  type        = string
  default     = ""
}

variable "s3_buckets" {
  description = <<-EOT
    Map of logical name => S3 bucket configuration. Each key creates one aws_s3_bucket; logical keys are stable
    Terraform map keys (e.g. app-uploads, logs). The bucket attribute is the global AWS bucket name. Leave empty or
    omit to create no application buckets (state bucket tf_state_bucket is separate).
  EOT
  type = map(object({
    bucket             = string
    force_destroy      = optional(bool, false)
    versioning_enabled = optional(bool, false)
    tags               = optional(map(string), {})
  }))
  default = {}
}

variable "sqs_queues" {
  description = <<-EOT
    Map of logical name => SQS queue configuration. Queues are created in aws_region via the AWS provider.
    Set fifo_queue = true for FIFO queues — name must end with .fifo. When dlq_enabled = true, a companion
    dead-letter queue is created (named <name>-dlq or <name>-dlq.fifo) and wired as the redrive target.
    dlq_max_receive_count controls how many receive attempts before a message is moved to the DLQ.
    receive_wait_time_seconds > 0 enables long polling (up to 20 s). Leave sqs_queues empty to create no queues.
  EOT
  type = map(object({
    name                       = string
    fifo_queue                 = optional(bool, false)
    visibility_timeout_seconds = optional(number, 30)
    message_retention_seconds  = optional(number, 345600)
    max_message_size           = optional(number, 262144)
    delay_seconds              = optional(number, 0)
    receive_wait_time_seconds  = optional(number, 0)
    dlq_enabled                = optional(bool, false)
    dlq_max_receive_count      = optional(number, 3)
    tags                       = optional(map(string), {})
  }))
  default = {}
}

variable "iam_users" {
  description = <<-EOT
    Map of logical name => IAM user configuration. Each key creates one aws_iam_user with a programmatic access key
    and an inline policy. Logical keys are stable Terraform map keys (e.g. app-backend, worker).
    username is the IAM user name in AWS.

    s3_access is a list of permission groups, each targeting a subset of buckets with specific actions.
    This allows different permissions on different buckets for the same user.
      bucket_keys    — list of logical bucket keys from s3_buckets, or ["*"] to target all buckets in this layer.
      bucket_actions — actions applied to the bucket ARN itself (default: s3:ListBucket, s3:GetBucketLocation).
      object_actions — actions applied to objects inside the bucket (default: s3:GetObject, s3:PutObject, s3:DeleteObject).

    sqs_access is a list of permission groups, each targeting a subset of queues with specific actions.
    This allows different permissions on different queues for the same user.
      queue_keys — list of logical queue keys from sqs_queues, or ["*"] to target all queues in this layer.
      actions    — SQS actions applied to the queue ARN (default: Send, Receive, Delete, GetQueueAttributes, GetQueueUrl).

    Access key ID and secret are stored in Terraform state and emitted as a sensitive output.
    Retrieve with: tofu output -json iam_users
    Leave empty or omit to create no IAM users.
  EOT
  type = map(object({
    username = string
    s3_access = optional(list(object({
      bucket_keys    = list(string)
      bucket_actions = optional(list(string), ["s3:ListBucket", "s3:GetBucketLocation"])
      object_actions = optional(list(string), ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"])
    })), [])
    sqs_access = optional(list(object({
      queue_keys = list(string)
      actions    = optional(list(string), ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"])
    })), [])
    tags = optional(map(string), {})
  }))
  default = {}
}

variable "computes" {
  description = <<-EOT
    Declarative VM layout for AWS and GCP. Subnet and network identifiers resolve from networking remote state
    (networking_tf_state_key). Each instance sets subnet_key to match networking outputs: aws_networking.subnet_ids
    or gcp_networking.subnetwork_ids (same flattened keys as the networking modules, e.g. core-public-public-a or
    qa-primary-private-qa-private-subnet). Optional vpc_name and network_name are applied as tags (AWS) or metadata (GCP).
    On GCP, vpc_name should match the networking VPC key so Cloud NAT can be correlated: this layer merges optional
    metadata keys cloud-nat-* when gcp_networking.cloud_nat has an entry for "<vpc_name>--<region>" (region from zone).
    Outbound internet via Cloud NAT does not need a separate attachment—omit external_static_ip_key for a private-only NIC.
    The gcp_compute module also exposes cloud_nat in outputs and in local_exec templates (cloud_nat, cloud_nat_enabled,
    cloud_nat_lookup_key, cloud_nat_for_instance when vpc_name is set).
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
    instance_id, ansible_user (ubuntu/debian or ec2-user/ubuntu on AWS), and on GCP also zone. In .tfvars, escape
    Terraform string interpolation for template placeholders (see example tfvars).
    For GCP SSH from local_exec, set root variable gcp_compute_ssh_public_key_path to your .pub file so instance metadata
    authorizes the matching private key (no ssh-copy-id needed).
  EOT
  type        = any
  default     = {}
}
