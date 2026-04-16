locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "global_identity_layer"
}

output "workspace" {
  value = local.workspace
}
