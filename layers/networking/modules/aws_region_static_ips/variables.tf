variable "region" {
  description = "AWS region for this module (same as provider region)."
  type        = string
}

variable "elastic_ips" {
  description = "Map of logical name => { optional tags } for VPC-scoped Elastic IPs."
  type        = map(any)
}
