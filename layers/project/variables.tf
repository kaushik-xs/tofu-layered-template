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
