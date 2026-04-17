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
