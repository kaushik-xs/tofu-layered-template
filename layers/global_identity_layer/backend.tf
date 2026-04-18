# Remote state is supplied at init via -backend-config (scripts/tofu-init-from-tfvars.sh reads tf_state_* from
# terraform.<AWS_PROFILE>.tfvars). The backend block cannot use root module variables — if it did, tofu init
# would prompt for those variables even when passing -backend-config.
#
# Where state lives:
# - Resource state is stored in S3 at s3://<tf_state_bucket>/<full state key> after init with -backend-config.
#   scripts/tofu-layer-run.sh uses tf_state_key from tfvars as a prefix and sets key to <tf_state_key>/terraform_<AWS_PROFILE>.tfstate.
# - Local OpenTofu metadata lives under TF_DATA_DIR (see scripts/tofu-layer-run.sh), typically
#   .terraform/terraform_<AWS_PROFILE>/terraform.tfstate — backend config cache only, not the S3 state snapshot.
# - A `terraform.tfstate` file in this directory (same level as *.tf) would mean local state — avoid that;
#   use init with the same backend flags as the scripts, or `tofu init -migrate-state` when switching backends.
terraform {
  backend "s3" {}
}
