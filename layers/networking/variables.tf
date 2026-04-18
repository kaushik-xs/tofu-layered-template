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
