variable "region" {
  description = "AWS region for this module instance (declared on the module provider)."
  type        = string
}

variable "vpcs" {
  description = "Map of VPC name => { cidr_block, optional tags, subnets = { tier_name = [ { name, cidr_block, availability_zone, type } ] } }."
  type        = map(any)
}

variable "enable_nat_gateway" {
  description = "When true, create one NAT gateway (with an Elastic IP) per VPC that has both a public and a private subnet, and route the private subnets' default traffic through it so private VMs get outbound internet."
  type        = bool
  default     = true
}

variable "ssh_ingress_source_ranges" {
  description = <<-EOT
    Default CIDRs allowed to reach tcp/22 on the per-VPC ssh security group.
    Per-VPC override: set ssh_ingress_source_ranges inside a vpcs entry.
    Empty list (and no per-VPC override) = SG created with egress-only, no ssh ingress.
  EOT
  type        = list(string)
  default     = []
}

variable "db_ingress_source_ranges" {
  description = <<-EOT
    Default CIDRs allowed to reach the DB ports (var.db_ports) on the per-VPC ssh security group. Instances on the
    same SG (e.g. app + db) reach each other when this is the VPC CIDR. Per-VPC override: set db_ingress_source_ranges
    inside a vpcs entry. Empty list (and no per-VPC override) = no DB ingress rule.
  EOT
  type        = list(string)
  default     = []
}

variable "db_ports" {
  description = "TCP ports opened by the DB ingress rule (e.g. 5432 PostgreSQL, 6379 Redis, 5672 AMQP/RabbitMQ)."
  type        = list(number)
  default     = [5432, 6379, 5672]
}

variable "web_ingress_source_ranges" {
  description = <<-EOT
    Default CIDRs allowed to reach the web ports (var.web_ports) on the per-VPC ssh security group.
    Use ["0.0.0.0/0"] for public HTTP/HTTPS (e.g. Caddy + Let's Encrypt ACME HTTP-01 on tcp/80).
    Per-VPC override: set web_ingress_source_ranges inside a vpcs entry.
    Empty list (and no per-VPC override) = no web ingress rule.
  EOT
  type        = list(string)
  default     = []
}

variable "web_ports" {
  description = "TCP ports opened by the web ingress rule (e.g. 80 HTTP / ACME HTTP-01, 443 HTTPS)."
  type        = list(number)
  default     = [80, 443]
}
