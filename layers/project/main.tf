locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "project"
}

output "workspace" {
  value = local.workspace
}
