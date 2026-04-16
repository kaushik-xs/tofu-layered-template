locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "networking_layer"
}

output "workspace" {
  value = local.workspace
}
