# Remote state is supplied at init via -backend-config (scripts/tofu-init-from-tfvars.sh reads tf_state_* from
# terraform.<AWS_PROFILE>.tfvars). The backend block cannot use root module variables — if it did, tofu init
# would prompt for those variables even when passing -backend-config.
#
# Where state lives:
# - Resource state is stored in S3 at s3://<tf_state_bucket>/<tf_state_key> after init with -backend-config.
# - `.terraform/terraform.tfstate` (under this layer) only caches backend configuration; it is not a copy of
#   the full remote state payload.
# - A `terraform.tfstate` file in this directory (same level as *.tf) would mean local state — avoid that;
#   use init with the same backend flags as the scripts, or `tofu init -migrate-state` when switching backends.
terraform {
  backend "s3" {}
}
