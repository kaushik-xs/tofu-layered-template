locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "platform_data_layer"
}

output "workspace" {
  value = local.workspace
}
