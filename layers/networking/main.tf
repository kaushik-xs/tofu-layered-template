locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "networking"
}

output "workspace" {
  value = local.workspace
}
