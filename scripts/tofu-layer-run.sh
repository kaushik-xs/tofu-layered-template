#!/usr/bin/env bash
#
# Runs OpenTofu for a single layer with plan or apply.
#
# Backend config (bucket, key, region, encrypt) is read from the same tfvars as
# scripts/tofu-init-from-tfvars.sh: terraform.<AWS_PROFILE>.tfvars must define
# tf_state_bucket, tf_state_key, tf_state_region, tf_state_encrypt.
#
# Usage:
#   AWS_PROFILE=<name> ./scripts/tofu-layer-run.sh <layer_name> <layer_dir> <workspace> <action>
#
# Required env:
#   AWS_PROFILE  Selects terraform.<profile>.tfvars in <layer_dir> (backend + -var-file).
#
# Required args:
#   <layer_name>   Logical name (echo only; state key comes from tfvars)
#   <layer_dir>    Path to the layer directory
#   <workspace>    Label for the run (echo only; state key comes from tfvars)
#   <action>       Either "plan" or "apply"
#
# Optional env:
#   TF_STATE_DYNAMODB_TABLE=<table>  Enable state locking with DynamoDB (backend-config)
#
# Init behavior:
#   The layer's `.terraform/` directory is removed before each run, then `tofu init -reconfigure`
#   runs so backend config and providers are always freshly initialized for that layer.
#   Remote state in S3 is unchanged; only the local working directory cache is cleared.
#
# Example:
#   AWS_PROFILE=regere ./scripts/tofu-layer-run.sh global_identity_layer layers/global_identity_layer dev plan
#
set -euo pipefail

EXPECTED_TOFU_VERSION="1.11.6"

LAYER_NAME="${1:?layer_name is required}"
LAYER_DIR="${2:?layer_dir is required}"
WORKSPACE_NAME="${3:?workspace is required}"
ACTION="${4:?action is required}"

: "${AWS_PROFILE:?AWS_PROFILE is required (selects terraform.<profile>.tfvars; same as tofu-init-from-tfvars.sh)}"

TFVARS_PATH="${LAYER_DIR}/terraform.${AWS_PROFILE}.tfvars"
if [[ ! -f "${TFVARS_PATH}" ]]; then
  echo "tfvars file not found: ${TFVARS_PATH}" >&2
  exit 1
fi

tf_state_bucket=""
tf_state_key=""
tf_state_region=""
tf_state_encrypt=""

while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  if [[ "${line}" =~ ^[[:space:]]*tf_state_bucket[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
    tf_state_bucket="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ ^[[:space:]]*tf_state_key[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
    tf_state_key="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ ^[[:space:]]*tf_state_region[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
    tf_state_region="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ ^[[:space:]]*tf_state_encrypt[[:space:]]*=[[:space:]]*(true|false) ]]; then
    tf_state_encrypt="${BASH_REMATCH[1]}"
  fi
done < "${TFVARS_PATH}"

: "${tf_state_bucket:?tf_state_bucket not found in ${TFVARS_PATH}}"
: "${tf_state_key:?tf_state_key not found in ${TFVARS_PATH}}"
: "${tf_state_region:?tf_state_region not found in ${TFVARS_PATH}}"
: "${tf_state_encrypt:?tf_state_encrypt not found in ${TFVARS_PATH}}"

TF_STATE_DYNAMODB_TABLE="${TF_STATE_DYNAMODB_TABLE:-}"

ACTUAL_TOFU_VERSION="$(tofu version -json | jq -r '.terraform_version')"
if [[ "${ACTUAL_TOFU_VERSION}" != "${EXPECTED_TOFU_VERSION}" ]]; then
  echo "Expected OpenTofu ${EXPECTED_TOFU_VERSION}, found ${ACTUAL_TOFU_VERSION}"
  exit 1
fi

if [[ "${ACTION}" != "plan" && "${ACTION}" != "apply" ]]; then
  echo "Action must be either 'plan' or 'apply'."
  exit 1
fi

echo "AWS profile: ${AWS_PROFILE}"
echo "Var file:    ${TFVARS_PATH}"
echo "Backend:     s3://${tf_state_bucket}/${tf_state_key} (region ${tf_state_region}, encrypt=${tf_state_encrypt})"
echo "Layer: ${LAYER_NAME}  Directory: ${LAYER_DIR}  Workspace: ${WORKSPACE_NAME}  Action: ${ACTION}"
read -r -p "Continue? [y/N] " _tofu_layer_run_confirm
case "${_tofu_layer_run_confirm}" in
  [yY]|[yY][eE][sS]) ;;
  *)
    echo "Aborted."
    exit 1
    ;;
esac

cd "${LAYER_DIR}"

if [[ -d .terraform ]]; then
  echo "Removing ${LAYER_DIR}/.terraform"
  rm -rf .terraform
fi

TOFU_VARFILE_ARGS=("-var-file=terraform.${AWS_PROFILE}.tfvars")

INIT_ARGS=(
  "-backend-config=bucket=${tf_state_bucket}"
  "-backend-config=key=${tf_state_key}"
  "-backend-config=region=${tf_state_region}"
  "-backend-config=encrypt=${tf_state_encrypt}"
)

if [[ -n "${TF_STATE_DYNAMODB_TABLE}" ]]; then
  INIT_ARGS+=("-backend-config=dynamodb_table=${TF_STATE_DYNAMODB_TABLE}")
fi

tofu init -reconfigure "${INIT_ARGS[@]}"
# Backend key comes from tf_state_key in tfvars (same contract as tofu-init-from-tfvars.sh).
# Do not use OpenTofu workspaces here, otherwise S3 backend prepends
# workspace prefixes such as "env:/<workspace>/...".

tofu validate "${TOFU_VARFILE_ARGS[@]}"

if [[ "${ACTION}" == "plan" ]]; then
  tofu plan "${TOFU_VARFILE_ARGS[@]}"
else
  tofu apply -auto-approve "${TOFU_VARFILE_ARGS[@]}"
fi
