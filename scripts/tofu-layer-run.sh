#!/usr/bin/env bash
set -euo pipefail

EXPECTED_TOFU_VERSION="1.11.6"

LAYER_NAME="${1:?layer_name is required}"
LAYER_DIR="${2:?layer_dir is required}"
WORKSPACE_NAME="${3:?workspace is required}"
ACTION="${4:?action is required}"

: "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"
: "${TF_STATE_REGION:?TF_STATE_REGION is required}"

TF_STATE_DYNAMODB_TABLE="${TF_STATE_DYNAMODB_TABLE:-}"
TF_STATE_KEY="opentofu/${LAYER_NAME}/${WORKSPACE_NAME}/terraform.tfstate"

ACTUAL_TOFU_VERSION="$(tofu version -json | jq -r '.terraform_version')"
if [[ "${ACTUAL_TOFU_VERSION}" != "${EXPECTED_TOFU_VERSION}" ]]; then
  echo "Expected OpenTofu ${EXPECTED_TOFU_VERSION}, found ${ACTUAL_TOFU_VERSION}"
  exit 1
fi

if [[ "${ACTION}" != "plan" && "${ACTION}" != "apply" ]]; then
  echo "Action must be either 'plan' or 'apply'."
  exit 1
fi

cd "${LAYER_DIR}"

INIT_ARGS=(
  "-backend-config=bucket=${TF_STATE_BUCKET}"
  "-backend-config=region=${TF_STATE_REGION}"
  "-backend-config=key=${TF_STATE_KEY}"
)

if [[ -n "${TF_STATE_DYNAMODB_TABLE}" ]]; then
  INIT_ARGS+=("-backend-config=dynamodb_table=${TF_STATE_DYNAMODB_TABLE}")
fi

tofu init -reconfigure "${INIT_ARGS[@]}"
# Keep backend object path deterministic via TF_STATE_KEY.
# Do not use OpenTofu workspaces here, otherwise S3 backend prepends
# workspace prefixes such as "env:/<workspace>/...".

tofu validate

if [[ "${ACTION}" == "plan" ]]; then
  tofu plan
else
  tofu apply -auto-approve
fi
