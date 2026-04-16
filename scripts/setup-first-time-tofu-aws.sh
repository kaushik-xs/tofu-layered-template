#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/setup-first-time-tofu-aws.sh \
    [--tfvars layers/global_identity_layer/terraform.tfvars] \
    [--profile tofu-backend] \
    [--layer-dir layers/global_identity_layer]

Description:
  First-time helper for OpenTofu S3 backend authentication.
  - Reads AWS credentials from terraform.tfvars:
      AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, optional AWS_SESSION_TOKEN
      and aws_region (fallback: ap-south-1)
  - Creates/updates ~/.aws/credentials and ~/.aws/config for a profile
  - Exports AWS_PROFILE and AWS_REGION for this script run
  - Runs 'tofu init -reconfigure' in the target layer
EOF
}

PROFILE="tofu-backend"
REGION="ap-south-1"
LAYER_DIR="layers/global_identity_layer"
TFVARS_PATH="${LAYER_DIR}/terraform.tfvars"
ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""
SESSION_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --tfvars)
      TFVARS_PATH="$2"
      shift 2
      ;;
    --layer-dir)
      LAYER_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ! -d "${LAYER_DIR}" ]]; then
  echo "Error: layer directory not found: ${LAYER_DIR}"
  exit 1
fi

if [[ ! -f "${TFVARS_PATH}" ]]; then
  echo "Error: terraform tfvars file not found: ${TFVARS_PATH}"
  exit 1
fi

read_tfvar() {
  local key="$1"
  local file="$2"
  python3 - "$key" "$file" <<'PY'
import re
import sys

key, path = sys.argv[1], sys.argv[2]
pattern = re.compile(r'^\s*' + re.escape(key) + r'\s*=\s*"(.*)"\s*$')
value = ""
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        m = pattern.match(line.rstrip("\n"))
        if m:
            value = m.group(1)
            break
print(value)
PY
}

ACCESS_KEY_ID="$(read_tfvar "AWS_ACCESS_KEY_ID" "${TFVARS_PATH}")"
SECRET_ACCESS_KEY="$(read_tfvar "AWS_SECRET_ACCESS_KEY" "${TFVARS_PATH}")"
SESSION_TOKEN="$(read_tfvar "AWS_SESSION_TOKEN" "${TFVARS_PATH}")"
TFVARS_REGION="$(read_tfvar "aws_region" "${TFVARS_PATH}")"

if [[ -n "${TFVARS_REGION}" ]]; then
  REGION="${TFVARS_REGION}"
fi

if [[ -z "${ACCESS_KEY_ID}" || -z "${SECRET_ACCESS_KEY}" ]]; then
  echo "Error: terraform.tfvars must define AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
  echo "Checked: ${TFVARS_PATH}"
  exit 1
fi

AWS_DIR="${HOME}/.aws"
CREDENTIALS_FILE="${AWS_DIR}/credentials"
CONFIG_FILE="${AWS_DIR}/config"

mkdir -p "${AWS_DIR}"
touch "${CREDENTIALS_FILE}" "${CONFIG_FILE}"

python3 - "${CREDENTIALS_FILE}" "${PROFILE}" "${ACCESS_KEY_ID}" "${SECRET_ACCESS_KEY}" "${SESSION_TOKEN}" <<'PY'
import configparser
import os
import sys

credentials_file, profile, access_key_id, secret_access_key, session_token = sys.argv[1:]

cfg = configparser.RawConfigParser()
cfg.read(credentials_file)
if not cfg.has_section(profile):
    cfg.add_section(profile)
cfg.set(profile, "aws_access_key_id", access_key_id)
cfg.set(profile, "aws_secret_access_key", secret_access_key)
if session_token:
    cfg.set(profile, "aws_session_token", session_token)
elif cfg.has_option(profile, "aws_session_token"):
    cfg.remove_option(profile, "aws_session_token")

with open(credentials_file, "w", encoding="utf-8") as fh:
    cfg.write(fh)
PY

python3 - "${CONFIG_FILE}" "${PROFILE}" "${REGION}" <<'PY'
import configparser
import sys

config_file, profile, region = sys.argv[1:]
section = "default" if profile == "default" else f"profile {profile}"

cfg = configparser.RawConfigParser()
cfg.read(config_file)
if not cfg.has_section(section):
    cfg.add_section(section)
cfg.set(section, "region", region)
cfg.set(section, "output", "json")

with open(config_file, "w", encoding="utf-8") as fh:
    cfg.write(fh)
PY

export AWS_PROFILE="${PROFILE}"
export AWS_REGION="${REGION}"

echo "Loaded AWS credentials from ${TFVARS_PATH}."
echo "Configured AWS profile '${PROFILE}' in ${CREDENTIALS_FILE} and ${CONFIG_FILE}."
echo "Running tofu init in ${LAYER_DIR}..."

(
  cd "${LAYER_DIR}"
  tofu init -reconfigure
)

cat <<EOF

Success.
For future shell sessions, run:
  export AWS_PROFILE=${PROFILE}
  export AWS_REGION=${REGION}
EOF
