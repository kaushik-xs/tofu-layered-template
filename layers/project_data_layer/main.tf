locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "project_data_layer"
}

output "workspace" {
  value = local.workspace
}
