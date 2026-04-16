locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "project_layer"
}

output "workspace" {
  value = local.workspace
}
