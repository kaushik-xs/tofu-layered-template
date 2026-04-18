locals {
  workspace = terraform.workspace
}

output "layer_name" {
  value = "platform"
}

output "workspace" {
  value = local.workspace
}
