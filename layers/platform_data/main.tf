locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "platform_data"
}

output "workspace" {
  value = local.workspace
}
