#!/usr/bin/env bash
#
# s3-bucket-migrate.sh  —  LOCAL machine script
#
# Migrates objects between two S3 buckets in different AWS regions.
# Uses AWS named profiles (configured via ~/.aws/credentials or SSO).
#
# Usage:
#   ./scripts/migration/aws/s3-bucket-migrate.sh
#
# What this script does:
#   1. Prompts for all required values (source + destination, nothing hardcoded)
#   2. Validates both AWS profiles can reach their respective buckets
#   3. Offers migration mode: full copy or prefix-scoped copy
#   4. Syncs objects from source bucket → destination bucket using aws s3 sync
#   5. Optionally verifies object counts match after the sync
#
# Previous values are saved to ~/.config/s3-migration/s3-bucket-migrate.conf
# and used as defaults on subsequent runs.
#
set -euo pipefail

# ── Config file ───────────────────────────────────────────────────────────────
CONF_DIR="${HOME}/.config/s3-migration"
CONF_FILE="${CONF_DIR}/s3-bucket-migrate.conf"

PREV_SRC_PROFILE=""
PREV_SRC_BUCKET=""
PREV_SRC_REGION=""
PREV_SRC_PREFIX=""
PREV_DST_PROFILE=""
PREV_DST_BUCKET=""
PREV_DST_REGION=""
PREV_DST_PREFIX=""
PREV_MIGRATION_SCOPE=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# s3-migration — last used values (auto-generated, do not commit)
PREV_SRC_PROFILE="${SRC_PROFILE}"
PREV_SRC_BUCKET="${SRC_BUCKET}"
PREV_SRC_REGION="${SRC_REGION}"
PREV_SRC_PREFIX="${SRC_PREFIX:-}"
PREV_DST_PROFILE="${DST_PROFILE}"
PREV_DST_BUCKET="${DST_BUCKET}"
PREV_DST_REGION="${DST_REGION}"
PREV_DST_PREFIX="${DST_PREFIX:-}"
PREV_MIGRATION_SCOPE="${MIGRATION_SCOPE}"
CONF
}

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Prompt helper ─────────────────────────────────────────────────────────────
prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local required="${4:-true}"
  local value=""

  if [[ -n "$default" ]]; then
    prompt_text="${prompt_text} [${default}]"
  fi

  read -r -p "$(echo -e "${CYAN}?${NC} ${prompt_text}: ")" value

  if [[ -z "$value" && -n "$default" ]]; then
    value="$default"
  fi

  if [[ -z "$value" && "$required" == "true" ]]; then
    die "Value for '${var_name}' is required."
  fi

  printf -v "$var_name" '%s' "$value"
}

# ── Dependency check ──────────────────────────────────────────────────────────
command -v aws &>/dev/null || die "'aws' CLI is not installed or not in PATH."

# ── Step 1 — Load saved config ────────────────────────────────────────────────
load_config

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  S3 Bucket → S3 Bucket Migration          ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
echo "This script runs on your LOCAL machine."
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Step 2 — Migration scope ──────────────────────────────────────────────────
echo -e "${CYAN}?${NC} Migration scope:"
echo "    1) Full bucket  (copy all objects)"
echo "    2) Prefix only  (copy a specific prefix / folder)"

default_scope_num="1"
[[ "${PREV_MIGRATION_SCOPE}" == "prefix" ]] && default_scope_num="2"
read -r -p "$(echo -e "${CYAN}?${NC} Choice [${default_scope_num}]: ")" SCOPE_CHOICE
[[ -z "${SCOPE_CHOICE}" ]] && SCOPE_CHOICE="${default_scope_num}"

case "${SCOPE_CHOICE}" in
  1) MIGRATION_SCOPE="full" ;;
  2) MIGRATION_SCOPE="prefix" ;;
  *) die "Invalid choice '${SCOPE_CHOICE}'. Enter 1 or 2." ;;
esac

# ── Step 3 — Gather inputs ────────────────────────────────────────────────────
SRC_PREFIX=""; DST_PREFIX=""

echo
echo -e "${YELLOW}── Source bucket ────────────────────────────────────────${NC}"
prompt SRC_PROFILE "AWS profile for source account"  "${PREV_SRC_PROFILE}"
prompt SRC_BUCKET  "Source S3 bucket name"            "${PREV_SRC_BUCKET}"
prompt SRC_REGION  "Source bucket region"             "${PREV_SRC_REGION:-us-east-1}"

if [[ "${MIGRATION_SCOPE}" == "prefix" ]]; then
  prompt SRC_PREFIX "Source prefix (leave blank for bucket root)" "${PREV_SRC_PREFIX}" "false"
fi

echo
echo -e "${YELLOW}── Destination bucket ───────────────────────────────────${NC}"
prompt DST_PROFILE "AWS profile for destination account" "${PREV_DST_PROFILE}"
prompt DST_BUCKET  "Destination S3 bucket name"          "${PREV_DST_BUCKET}"
prompt DST_REGION  "Destination bucket region"           "${PREV_DST_REGION:-ap-southeast-1}"

if [[ "${MIGRATION_SCOPE}" == "prefix" ]]; then
  prompt DST_PREFIX "Destination prefix (leave blank for bucket root)" "${PREV_DST_PREFIX}" "false"
fi

# ── Build S3 URIs ─────────────────────────────────────────────────────────────
if [[ -n "${SRC_PREFIX}" ]]; then
  # Strip trailing slash from prefix, then add exactly one
  SRC_PREFIX="${SRC_PREFIX%/}/"
  SRC_URI="s3://${SRC_BUCKET}/${SRC_PREFIX}"
else
  SRC_URI="s3://${SRC_BUCKET}/"
fi

if [[ -n "${DST_PREFIX}" ]]; then
  DST_PREFIX="${DST_PREFIX%/}/"
  DST_URI="s3://${DST_BUCKET}/${DST_PREFIX}"
else
  DST_URI="s3://${DST_BUCKET}/"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Summary ──────────────────────────────────────────────${NC}"
echo "  Source profile : ${SRC_PROFILE}"
echo "  Source URI     : ${SRC_URI}  (${SRC_REGION})"
echo "  Dest profile   : ${DST_PROFILE}"
echo "  Dest URI       : ${DST_URI}  (${DST_REGION})"
echo "  Scope          : ${MIGRATION_SCOPE}"
echo
echo "  The sync will copy objects that are missing or differ in the destination."
echo "  Existing objects in the destination that are NOT in the source are left alone."
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# Save immediately after confirmation so values persist even if sync fails
save_config
success "Saved values to ${CONF_FILE}"

# ── Step 4 — Validate source access ──────────────────────────────────────────
info "Validating access to source bucket …"
aws s3api head-bucket \
  --bucket  "${SRC_BUCKET}" \
  --profile "${SRC_PROFILE}" \
  --region  "${SRC_REGION}" \
  > /dev/null \
  || die "Cannot access source bucket '${SRC_BUCKET}' with profile '${SRC_PROFILE}'."
success "Source bucket accessible."

# ── Step 5 — Validate destination access ─────────────────────────────────────
info "Validating access to destination bucket …"
aws s3api head-bucket \
  --bucket  "${DST_BUCKET}" \
  --profile "${DST_PROFILE}" \
  --region  "${DST_REGION}" \
  > /dev/null \
  || die "Cannot access destination bucket '${DST_BUCKET}' with profile '${DST_PROFILE}'."
success "Destination bucket accessible."

# ── Step 6 — Count source objects (for post-sync verification) ────────────────
info "Counting objects in source …"
SRC_COUNT=$(aws s3 ls "${SRC_URI}" \
  --profile "${SRC_PROFILE}" \
  --region  "${SRC_REGION}" \
  --recursive \
  | wc -l | tr -d ' ')
info "Source objects: ${SRC_COUNT}"

# ── Step 7 — Sync ─────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Syncing ──────────────────────────────────────────────${NC}"
info "Starting sync from ${SRC_URI} → ${DST_URI} …"
info "This may take a while depending on the amount of data."

# Cross-account cross-region sync: source credentials are used to read the
# objects; destination credentials are used to write. We achieve this by
# streaming through the local machine (aws s3 sync handles this natively when
# separate profiles are configured for each side, but aws s3 sync only accepts
# one set of credentials). We therefore use a two-step approach:
#
#   aws s3 sync with --source-region and a single profile works fine for
#   same-account migrations. For cross-account we run the sync loop manually.
#
# Detect whether both profiles resolve to the same account:
SRC_ACCOUNT=$(aws sts get-caller-identity --profile "${SRC_PROFILE}" --query Account --output text 2>/dev/null || echo "")
DST_ACCOUNT=$(aws sts get-caller-identity --profile "${DST_PROFILE}" --query Account --output text 2>/dev/null || echo "")

if [[ "${SRC_ACCOUNT}" == "${DST_ACCOUNT}" && -n "${SRC_ACCOUNT}" ]]; then
  # Same account — a single sync call is sufficient
  info "Same AWS account detected — using direct aws s3 sync."
  aws s3 sync "${SRC_URI}" "${DST_URI}" \
    --profile       "${SRC_PROFILE}" \
    --source-region "${SRC_REGION}" \
    --region        "${DST_REGION}" \
    --no-progress
else
  # Cross-account — pipe each object through the local machine
  info "Cross-account migration detected — streaming objects via local machine."
  warn "Large objects will be buffered to disk temporarily under /tmp/s3-migrate."
  STAGING_DIR="$(mktemp -d /tmp/s3-migrate.XXXXXX)"
  trap 'rm -rf "${STAGING_DIR}"' EXIT

  OBJECT_LIST=$(aws s3 ls "${SRC_URI}" \
    --profile "${SRC_PROFILE}" \
    --region  "${SRC_REGION}" \
    --recursive \
    | awk '{print $4}')

  TOTAL=$(echo "${OBJECT_LIST}" | grep -c . || true)
  CURRENT=0

  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    CURRENT=$((CURRENT + 1))

    # Compute the destination key: strip src prefix, prepend dst prefix
    if [[ -n "${SRC_PREFIX}" ]]; then
      relative_key="${key#${SRC_PREFIX}}"
    else
      relative_key="${key}"
    fi

    if [[ -n "${DST_PREFIX}" ]]; then
      dst_key="${DST_PREFIX}${relative_key}"
    else
      dst_key="${relative_key}"
    fi

    # Skip if the object already exists in the destination with the same size
    src_size=$(aws s3 ls "s3://${SRC_BUCKET}/${key}" \
      --profile "${SRC_PROFILE}" --region "${SRC_REGION}" \
      | awk '{print $3}')

    dst_size=$(aws s3 ls "s3://${DST_BUCKET}/${dst_key}" \
      --profile "${DST_PROFILE}" --region "${DST_REGION}" \
      2>/dev/null | awk '{print $3}' || echo "")

    if [[ "${src_size}" == "${dst_size}" && -n "${dst_size}" ]]; then
      info "[${CURRENT}/${TOTAL}] Skipping (exists, same size): ${dst_key}"
      continue
    fi

    info "[${CURRENT}/${TOTAL}] Copying: ${key} → ${dst_key}"

    local_tmp="${STAGING_DIR}/$(basename "${key}")"

    aws s3 cp "s3://${SRC_BUCKET}/${key}" "${local_tmp}" \
      --profile "${SRC_PROFILE}" \
      --region  "${SRC_REGION}" \
      --quiet

    aws s3 cp "${local_tmp}" "s3://${DST_BUCKET}/${dst_key}" \
      --profile "${DST_PROFILE}" \
      --region  "${DST_REGION}" \
      --quiet

    rm -f "${local_tmp}"
  done <<< "${OBJECT_LIST}"
fi

success "Sync complete."

# ── Step 8 — Post-sync verification ──────────────────────────────────────────
echo
info "Verifying destination object count …"
DST_COUNT=$(aws s3 ls "${DST_URI}" \
  --profile "${DST_PROFILE}" \
  --region  "${DST_REGION}" \
  --recursive \
  | wc -l | tr -d ' ')

echo
echo -e "${YELLOW}── Verification ─────────────────────────────────────────${NC}"
echo "  Source objects      : ${SRC_COUNT}"
echo "  Destination objects : ${DST_COUNT}"

if [[ "${SRC_COUNT}" -eq "${DST_COUNT}" ]]; then
  success "Object counts match."
elif [[ "${DST_COUNT}" -gt "${SRC_COUNT}" ]]; then
  warn "Destination has more objects (${DST_COUNT} > ${SRC_COUNT})."
  warn "This is expected if the destination already had objects before the sync."
else
  warn "Destination has fewer objects than source (${DST_COUNT} < ${SRC_COUNT})."
  warn "Some objects may not have been transferred. Re-run the script to retry."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Migration complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo
echo "  ${SRC_URI}  →  ${DST_URI}"
echo "  Objects transferred / verified: ${DST_COUNT}"
echo
echo "Next steps:"
echo "  - Update any application configs pointing at the old bucket."
echo "  - If this was a one-time migration, consider setting a bucket lifecycle"
echo "    policy on the source to expire objects after a cut-over period."
