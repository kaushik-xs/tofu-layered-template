# Remote state is supplied at init via -backend-config; scripts/tofu-layer-run.sh reads tf_state_* from
# terraform.<AWS_PROFILE>.<workspace>.tfvars. The backend block cannot use root module variables — if it did,
# tofu init would prompt for those variables even when passing -backend-config.
#
# Where state lives:
# - Resource state is stored in S3 after init with -backend-config. The configured key is
#   <tf_state_key>/terraform_<AWS_PROFILE>.tfstate. Named OpenTofu workspaces use objects under
#   env:/<workspace>/... (see tofu-layer-run.sh).
# - Local OpenTofu metadata lives under TF_DATA_DIR (see scripts/tofu-layer-run.sh), typically
#   .terraform/terraform_<AWS_PROFILE>_<workspace>/terraform.tfstate — backend config cache only, not the S3 snapshot.
# - A `terraform.tfstate` file in this directory (same level as *.tf) would mean local state — avoid that;
#   use init with the same backend flags as the scripts, or `tofu init -migrate-state` when switching backends.
terraform {
  backend "s3" {}
}
