#!/usr/bin/env bash
#
# Runs OpenTofu for a single layer with plan, apply, or destroy.
#
# Backend config (bucket, key prefix, region, encrypt) is read from the same tfvars as
# scripts/tofu-init-from-tfvars.sh: terraform.<AWS_PROFILE>.tfvars must define
# tf_state_bucket, tf_state_key, tf_state_region, tf_state_encrypt.
#
# tf_state_key is a path prefix (S3 key without the filename). The script sets the backend
# object key to: <tf_state_key>/terraform_<AWS_PROFILE>.tfstate
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
#   <action>       One of "plan", "apply", or "destroy"
#
# Optional env:
#   TF_STATE_DYNAMODB_TABLE=<table>     Enable state locking with DynamoDB (backend-config)
#   TF_DATA_DIR=<path>                  Override local OpenTofu data dir (default: <layer_dir>/.terraform/terraform_<AWS_PROFILE>)
#   TOFU_FORCE_RECONFIGURE=1            Always run `tofu init -reconfigure` (ignore fingerprint)
#
# Init behavior:
#   `tofu init -reconfigure` runs only when needed: first-time backend setup, backend settings in
#   tfvars changed (vs last successful run), or TOFU_FORCE_RECONFIGURE. Otherwise `tofu init` runs
#   without -reconfigure (refreshes providers/modules). A fingerprint file under TF_DATA_DIR tracks
#   the backend -backend-config values between runs.
#
# Local backend metadata (not the S3 state object) always uses the filename terraform.tfstate inside
# TF_DATA_DIR. The script sets TF_DATA_DIR to .terraform/terraform_<AWS_PROFILE> so each profile
# has a separate tree: .terraform/terraform_<AWS_PROFILE>/terraform.tfstate.
#
# Example:
#   AWS_PROFILE=<AWS_PROFILE> ./scripts/tofu-layer-run.sh global_identity_layer layers/global_identity_layer dev plan
#   AWS_PROFILE=<AWS_PROFILE> ./scripts/tofu-layer-run.sh global_identity_layer layers/global_identity_layer dev destroy
#
set -euo pipefail

# Print a copy-pasteable tofu line (cwd is the layer dir; TF_DATA_DIR affects local metadata paths).
_tofu_layer_run_print_tofu_cmd() {
  printf '+ '
  printf 'TF_DATA_DIR=%q ' "${TF_DATA_DIR}"
  printf '%q ' "$@"
  printf '\n'
}

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
tf_state_key_prefix=""
tf_state_region=""
tf_state_encrypt=""

while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  if [[ "${line}" =~ ^[[:space:]]*tf_state_bucket[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
    tf_state_bucket="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ ^[[:space:]]*tf_state_key[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
    tf_state_key_prefix="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ ^[[:space:]]*tf_state_region[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
    tf_state_region="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ ^[[:space:]]*tf_state_encrypt[[:space:]]*=[[:space:]]*(true|false) ]]; then
    tf_state_encrypt="${BASH_REMATCH[1]}"
  fi
done < "${TFVARS_PATH}"

: "${tf_state_bucket:?tf_state_bucket not found in ${TFVARS_PATH}}"
: "${tf_state_key_prefix:?tf_state_key not found in ${TFVARS_PATH}}"
: "${tf_state_region:?tf_state_region not found in ${TFVARS_PATH}}"
: "${tf_state_encrypt:?tf_state_encrypt not found in ${TFVARS_PATH}}"

tf_state_key_prefix="${tf_state_key_prefix%/}"
tf_state_key="${tf_state_key_prefix}/terraform_${AWS_PROFILE}.tfstate"

TF_STATE_DYNAMODB_TABLE="${TF_STATE_DYNAMODB_TABLE:-}"

ACTUAL_TOFU_VERSION="$(tofu version -json | jq -r '.terraform_version')"
if [[ "${ACTUAL_TOFU_VERSION}" != "${EXPECTED_TOFU_VERSION}" ]]; then
  echo "Expected OpenTofu ${EXPECTED_TOFU_VERSION}, found ${ACTUAL_TOFU_VERSION}"
  exit 1
fi

if [[ "${ACTION}" != "plan" && "${ACTION}" != "apply" && "${ACTION}" != "destroy" ]]; then
  echo "Action must be 'plan', 'apply', or 'destroy'."
  exit 1
fi

# Summary banner (colors only when stdout is a TTY and NO_COLOR is unset)
_tofu_layer_run_print_summary() {
  local _r _b _title _bar _plan_c _apply_c _destroy_c
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _r=$'\033[0m'
    _b=$'\033[1m'
    _title=$'\033[1;36m'
    _bar=$'\033[38;5;240m'
    _plan_c=$'\033[38;5;117m'
    _apply_c=$'\033[38;5;214m'
    _destroy_c=$'\033[38;5;196m'
  else
    _r=; _b=; _title=; _bar=; _plan_c=; _apply_c=; _destroy_c=
  fi

  local _lw=12
  local _uri="s3://${tf_state_bucket}/${tf_state_key}"
  local _meta="(region ${tf_state_region}, encrypt=${tf_state_encrypt})"

  # Prefix length before backend URI (emoji + label) — used to align the meta continuation
  local _vo
  _vo=$(printf '%s %-*s ' "☁️" "${_lw}" "Backend")
  _vo=${#_vo}

  local _mode
  if [[ "${ACTION}" == "plan" ]]; then
    _mode="📋  Plan — preview only · no writes"
  elif [[ "${ACTION}" == "apply" ]]; then
    _mode="🚀  Apply — will modify live infrastructure"
  else
    _mode="💥  Destroy — will delete managed infrastructure"
  fi

  local _action_row
  if [[ "${ACTION}" == "plan" ]]; then
    _action_row="$(printf '%s %-*s %s' "📋" "${_lw}" "Action" "plan")"
  elif [[ "${ACTION}" == "apply" ]]; then
    _action_row="$(printf '%s %-*s %s' "🚀" "${_lw}" "Action" "apply")"
  else
    _action_row="$(printf '%s %-*s %s' "💥" "${_lw}" "Action" "destroy")"
  fi

  local -a _rows=(
    "🧱 OpenTofu layer run"
    "${_mode}"
    "$(printf '%s %-*s %s' "🔐" "${_lw}" "AWS profile" "${AWS_PROFILE}")"
    "$(printf '%s %-*s %s' "📄" "${_lw}" "Var file" "${TFVARS_PATH}")"
    "$(printf '%s %-*s %s' "☁️" "${_lw}" "Backend" "${_uri}")"
    "$(printf '%*s%s' "${_vo}" "" "${_meta}")"
    "$(printf '%s %-*s %s' "🏗️" "${_lw}" "Layer" "${LAYER_NAME}")"
    "$(printf '%s %-*s %s' "📁" "${_lw}" "Directory" "${LAYER_DIR}")"
    "$(printf '%s %-*s %s' "🌿" "${_lw}" "Workspace" "${WORKSPACE_NAME}")"
    "${_action_row}"
  )

  local _max=0
  local _line
  for _line in "${_rows[@]}"; do
    ((${#_line} > _max)) && _max=${#_line}
  done

  local _w=$((_max + 2))
  ((_w < 46)) && _w=46

  local _rule
  _rule=$(printf '%*s' "$((_w + 2))" '' | tr ' ' '─')

  local _pad
  printf -v _pad '%-*s' "${_w}" "${_rows[0]}"

  printf '%s╭%s╮%s\n' "${_bar}" "${_rule}" "${_r}"
  printf '%s│  %s%s%s%s%s│%s\n' "${_bar}" "${_b}" "${_title}" "${_pad}" "${_r}" "${_bar}" "${_r}"

  printf -v _pad '%-*s' "${_w}" "${_rows[1]}"
  if [[ "${ACTION}" == "plan" ]]; then
    printf '%s│  %s%s%s%s│%s\n' "${_bar}" "${_plan_c}" "${_pad}" "${_r}" "${_bar}" "${_r}"
  elif [[ "${ACTION}" == "apply" ]]; then
    printf '%s│  %s%s%s%s│%s\n' "${_bar}" "${_apply_c}" "${_pad}" "${_r}" "${_bar}" "${_r}"
  else
    printf '%s│  %s%s%s%s│%s\n' "${_bar}" "${_destroy_c}" "${_pad}" "${_r}" "${_bar}" "${_r}"
  fi

  printf '%s├%s┤%s\n' "${_bar}" "${_rule}" "${_r}"

  local _i
  for ((_i = 2; _i < ${#_rows[@]}; _i++)); do
    printf -v _pad '%-*s' "${_w}" "${_rows[_i]}"
    printf '%s│  %s%s│%s\n' "${_bar}" "${_pad}" "${_bar}" "${_r}"
  done

  printf '%s╰%s╯%s\n' "${_bar}" "${_rule}" "${_r}"
  printf '\n'
}

_tofu_layer_run_print_summary

if [[ "${ACTION}" == "plan" ]]; then
  read -r -p "📋 Continue with plan? [y/N] " _tofu_layer_run_confirm
elif [[ "${ACTION}" == "apply" ]]; then
  read -r -p "🚀 Proceed with apply? [y/N] " _tofu_layer_run_confirm
else
  read -r -p "💥 Proceed with destroy? [y/N] " _tofu_layer_run_confirm
fi
case "${_tofu_layer_run_confirm}" in
  [yY]|[yY][eE][sS]) ;;
  *)
    echo "Aborted."
    exit 1
    ;;
esac

if [[ "${ACTION}" == "plan" ]]; then
  read -r -p "📋 Second confirmation: run plan now? [y/N] " _tofu_layer_run_confirm2
elif [[ "${ACTION}" == "apply" ]]; then
  read -r -p "🚀 Second confirmation: apply will modify live infrastructure. Continue? [y/N] " _tofu_layer_run_confirm2
else
  read -r -p "💥 Second confirmation: type the layer name '${LAYER_NAME}' exactly to destroy: " _tofu_layer_run_confirm2
fi

if [[ "${ACTION}" == "destroy" ]]; then
  if [[ "${_tofu_layer_run_confirm2}" != "${LAYER_NAME}" ]]; then
    echo "Layer name did not match. Aborted."
    exit 1
  fi
else
  case "${_tofu_layer_run_confirm2}" in
    [yY]|[yY][eE][sS]) ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
fi

cd "${LAYER_DIR}"

# Isolate local OpenTofu data per AWS profile. Basename inside TF_DATA_DIR is always terraform.tfstate
# (OpenTofu/Terraform fixed); we use a profile-named directory under .terraform/ instead.
export TF_DATA_DIR="${TF_DATA_DIR:-${PWD}/.terraform/terraform_${AWS_PROFILE}}"

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

# Backend object key is <tf_state_key from tfvars>/terraform_<AWS_PROFILE>.tfstate.
# Do not use OpenTofu workspaces here, otherwise S3 backend prepends
# workspace prefixes such as "env:/<workspace>/...".

CURRENT_BACKEND_FP="${tf_state_bucket}|${tf_state_key}|${tf_state_region}|${tf_state_encrypt}|${TF_STATE_DYNAMODB_TABLE:-}"
BACKEND_META_FILE="${TF_DATA_DIR}/terraform.tfstate"
BACKEND_FP_FILE="${TF_DATA_DIR}/.tofu-layer-run-backend-fingerprint"
PREV_BACKEND_FP=""
if [[ -f "${BACKEND_FP_FILE}" ]]; then
  PREV_BACKEND_FP="$(<"${BACKEND_FP_FILE}")"
fi

if [[ -n "${TOFU_FORCE_RECONFIGURE:-}" ]]; then
  _tofu_layer_run_print_tofu_cmd tofu init -reconfigure "${INIT_ARGS[@]}"
  tofu init -reconfigure "${INIT_ARGS[@]}"
elif [[ ! -f "${BACKEND_META_FILE}" ]]; then
  _tofu_layer_run_print_tofu_cmd tofu init "${INIT_ARGS[@]}"
  tofu init "${INIT_ARGS[@]}"
elif [[ "${PREV_BACKEND_FP}" == "${CURRENT_BACKEND_FP}" ]]; then
  _tofu_layer_run_print_tofu_cmd tofu init
  tofu init
else
  _tofu_layer_run_print_tofu_cmd tofu init -reconfigure "${INIT_ARGS[@]}"
  tofu init -reconfigure "${INIT_ARGS[@]}"
fi

printf '%s\n' "${CURRENT_BACKEND_FP}" > "${BACKEND_FP_FILE}"

_tofu_layer_run_print_tofu_cmd tofu validate "${TOFU_VARFILE_ARGS[@]}"
tofu validate "${TOFU_VARFILE_ARGS[@]}"

if [[ "${ACTION}" == "plan" ]]; then
  _tofu_layer_run_print_tofu_cmd tofu plan "${TOFU_VARFILE_ARGS[@]}"
  tofu plan "${TOFU_VARFILE_ARGS[@]}"
elif [[ "${ACTION}" == "apply" ]]; then
  _tofu_layer_run_print_tofu_cmd tofu apply -auto-approve "${TOFU_VARFILE_ARGS[@]}"
  tofu apply -auto-approve "${TOFU_VARFILE_ARGS[@]}"
else
  _tofu_layer_run_print_tofu_cmd tofu destroy -auto-approve "${TOFU_VARFILE_ARGS[@]}"
  tofu destroy -auto-approve "${TOFU_VARFILE_ARGS[@]}"
fi
