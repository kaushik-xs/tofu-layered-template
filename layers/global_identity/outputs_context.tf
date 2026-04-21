output "aws_region" {
  description = "AWS region configured for this layer"
  value       = var.aws_region
}

output "gcp_project_id" {
  description = "GCP project ID configured for this layer"
  value       = var.gcp_project_id
}

output "gcp_region" {
  description = "GCP region configured for this layer"
  value       = var.gcp_region
}

output "layer_name" {
  value = "global_identity"
}

output "workspace" {
  value = local.workspace
}

output "route53_hosted_zone_ids" {
  description = "Map of hosted zone DNS name (each.key) to Route53 zone ID for aws_route53_zone.primary."
  value       = { for zone_name, z in aws_route53_zone.primary : zone_name => z.zone_id }
}
