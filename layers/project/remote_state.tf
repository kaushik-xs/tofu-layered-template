# Reads global_identity state from the same bucket layout as scripts/tofu-layer-run.sh:
# non-default workspace => <workspace>/<tf_state_key>/terraform_<AWS_PROFILE>.tfstate
# OpenTofu does not read AWS_PROFILE in HCL; scripts/tofu-layer-run.sh exports TF_VAR_aws_profile=$AWS_PROFILE
# for project so var.aws_profile matches the profile used in state object names.
locals {
  global_identity_remote_state_key = (
    var.global_identity_workspace == "default"
    ? "${var.global_identity_tf_state_key}/terraform_${var.aws_profile}.tfstate"
    : "${var.global_identity_workspace}/${var.global_identity_tf_state_key}/terraform_${var.aws_profile}.tfstate"
  )
}

data "terraform_remote_state" "global_identity" {
  backend = "s3"

  config = {
    bucket               = var.tf_state_bucket
    key                  = local.global_identity_remote_state_key
    region               = var.tf_state_region
    encrypt              = var.tf_state_encrypt
    workspace_key_prefix = ""
  }

  lifecycle {
    precondition {
      condition     = trimspace(var.aws_profile) != ""
      error_message = "aws_profile must be set (TF_VAR_aws_profile from AWS_PROFILE when using scripts/tofu-layer-run.sh) so the remote state key matches terraform_<AWS_PROFILE>.tfstate."
    }
  }
}

output "global_identity_outputs" {
  description = "Root module outputs from global_identity (remote state)."
  value       = data.terraform_remote_state.global_identity.outputs
}
