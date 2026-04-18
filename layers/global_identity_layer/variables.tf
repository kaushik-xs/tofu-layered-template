variable "tf_state_bucket" {
  description = "S3 bucket for remote state (same value as tofu init -backend-config=bucket=...; set in terraform.<AWS_PROFILE>.tfvars)."
  type        = string
}

variable "tf_state_key" {
  description = "S3 object key for remote state (same as tofu init -backend-config=key=...)."
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

variable "github_owner" {
  description = "GitHub organization or user."
  type        = string
}

variable "github_token" {
  description = "GitHub token with required permissions."
  type        = string
  sensitive   = true
}

variable "vault_address" {
  description = "HashiCorp Vault address."
  type        = string
}

variable "vault_token" {
  description = "HashiCorp Vault token."
  type        = string
  sensitive   = true
}

variable "route53_hosted_zone_names" {
  description = "Route53 hosted zone domain names (for example, [\"example.com\", \"example.org\"])."
  type        = set(string)
}

variable "route53_records" {
  description = "Route53 records grouped by hosted zone name."
  type = map(list(object({
    name    = string
    type    = string
    ttl     = optional(number, 300)
    records = list(string)
  })))
  default = {}

  validation {
    condition = alltrue([
      for zone_name in keys(var.route53_records) :
      contains(var.route53_hosted_zone_names, zone_name)
    ])
    error_message = "All keys in route53_records must be present in route53_hosted_zone_names."
  }
}
