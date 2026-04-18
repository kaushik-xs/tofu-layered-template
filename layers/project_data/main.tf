locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "project_data"
}

output "workspace" {
  value = local.workspace
}
