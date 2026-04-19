#!/usr/bin/env bash
#
# cloudsql-export.sh  —  LOCAL machine script
#
# Exports a Cloud SQL (PostgreSQL) database to GCS, then downloads
# the dump to your local machine.
#
# Usage:
#   ./scripts/migration/gcp/cloudsql-export.sh
#
# What this script does:
#   1. Prompts you for all required values (nothing is hardcoded)
#   2. Creates a GCS bucket (if it doesn't already exist)
#   3. Grants the Cloud SQL service account write access to the bucket
#   4. Exports the database(s) from Cloud SQL → GCS (plain SQL, gzip-compressed)
#   5. Downloads the dump from GCS to your local machine
#
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Prompt helper (supports secret/hidden input) ──────────────────────────────
prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local secret="${4:-false}"
  local value=""

  if [[ -n "$default" ]]; then
    prompt_text="${prompt_text} [${default}]"
  fi

  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$(echo -e "${CYAN}?${NC} ${prompt_text}: ")" value
    echo
  else
    read -r -p "$(echo -e "${CYAN}?${NC} ${prompt_text}: ")" value
  fi

  if [[ -z "$value" && -n "$default" ]]; then
    value="$default"
  fi

  if [[ -z "$value" ]]; then
    die "Value for '${var_name}' is required."
  fi

  printf -v "$var_name" '%s' "$value"
}

# ── Dependency check ──────────────────────────────────────────────────────────
command -v gcloud &>/dev/null || die "'gcloud' is not installed or not in PATH."

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Cloud SQL → Local Machine (Export leg)   ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
echo "This script runs on your LOCAL machine."
echo "Answer each prompt — press Enter to accept a default where shown."
echo

# ── Gather inputs ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}── GCP / Cloud SQL ──────────────────────────────────────${NC}"
prompt PROJECT_ID       "GCP Project ID"
prompt SOURCE_INSTANCE  "Cloud SQL instance name"
prompt SOURCE_REGION    "Cloud SQL region" "asia-southeast1"

echo
echo -e "${CYAN}?${NC} Export scope:"
echo "    1) All databases"
echo "    2) Single database"
read -r -p "$(echo -e "${CYAN}?${NC} Choice [1/2]: ")" EXPORT_SCOPE_CHOICE

DB_NAME=""
case "${EXPORT_SCOPE_CHOICE}" in
  1)
    EXPORT_SCOPE="all"
    info "Will export all databases from '${SOURCE_INSTANCE}'."
    ;;
  2)
    EXPORT_SCOPE="single"
    prompt DB_NAME "Database name to export"
    ;;
  *)
    die "Invalid choice '${EXPORT_SCOPE_CHOICE}'. Enter 1 or 2."
    ;;
esac

echo
echo -e "${YELLOW}── GCS Export Bucket ────────────────────────────────────${NC}"
prompt BUCKET_NAME    "GCS bucket name for export" "cloudsql-export-${PROJECT_ID}"

echo
echo -e "${YELLOW}── Local paths ──────────────────────────────────────────${NC}"
prompt LOCAL_DUMP_DIR "Local directory to store the dump" "${HOME}/cloudsql-migration"

# ── Derive paths ──────────────────────────────────────────────────────────────
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
GCS_EXPORT_PREFIX="gs://${BUCKET_NAME}/exports/${SOURCE_INSTANCE}-${TIMESTAMP}"
LOCAL_DUMP_SUBDIR="${LOCAL_DUMP_DIR}/${SOURCE_INSTANCE}-${TIMESTAMP}"

echo
echo -e "${YELLOW}── Summary ──────────────────────────────────────────────${NC}"
echo "  Project       : ${PROJECT_ID}"
echo "  Instance      : ${SOURCE_INSTANCE}  (${SOURCE_REGION})"
if [[ "${EXPORT_SCOPE}" == "all" ]]; then
  echo "  Database      : (all — exported individually)"
else
  echo "  Database      : ${DB_NAME}"
fi
echo "  GCS prefix    : ${GCS_EXPORT_PREFIX}/<db>.sql.gz"
echo "  Local dump dir: ${LOCAL_DUMP_SUBDIR}/"
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Step 1 — Local dump directory ────────────────────────────────────────────
mkdir -p "${LOCAL_DUMP_SUBDIR}"
success "Local dump directory ready: ${LOCAL_DUMP_SUBDIR}"

# ── Step 2 — Create GCS bucket (idempotent) ──────────────────────────────────
info "Checking GCS bucket gs://${BUCKET_NAME} …"
if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
  warn "Bucket already exists — skipping creation."
else
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${SOURCE_REGION}" \
    --uniform-bucket-level-access
  success "Bucket created: gs://${BUCKET_NAME}"
fi

# ── Step 3 — Grant Cloud SQL SA access to bucket ─────────────────────────────
info "Resolving Cloud SQL service account …"
SOURCE_SA=$(gcloud sql instances describe "${SOURCE_INSTANCE}" \
  --project="${PROJECT_ID}" \
  --format="value(serviceAccountEmailAddress)")

[[ -n "$SOURCE_SA" ]] || die "Could not determine Cloud SQL service account for instance '${SOURCE_INSTANCE}'."
info "Cloud SQL SA: ${SOURCE_SA}"

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${SOURCE_SA}" \
  --role="roles/storage.objectAdmin" \
  --project="${PROJECT_ID}" &>/dev/null

success "IAM: objectAdmin granted to ${SOURCE_SA}"

# ── Step 4 — Export Cloud SQL → GCS ──────────────────────────────────────────
if [[ "${EXPORT_SCOPE}" == "all" ]]; then
  info "Listing user databases on '${SOURCE_INSTANCE}' …"
  DB_LIST=()
  while IFS= read -r db; do
    DB_LIST+=("$db")
  done < <(gcloud sql databases list \
    --instance="${SOURCE_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --format="value(name)" \
    | grep -vE '^(postgres|cloudsqladmin|template0|template1)$')

  [[ ${#DB_LIST[@]} -gt 0 ]] || die "No user databases found on instance '${SOURCE_INSTANCE}'."
  info "Databases to export: ${DB_LIST[*]}"
else
  DB_LIST=("${DB_NAME}")
fi
info "This may take several minutes per database …"

# ── Step 5 — Download dumps to local machine ─────────────────────────────────
for db in "${DB_LIST[@]}"; do
  GCS_DUMP_PATH="${GCS_EXPORT_PREFIX}/${db}.sql.gz"
  LOCAL_DUMP_PATH="${LOCAL_DUMP_SUBDIR}/${db}.sql.gz"

  info "Exporting '${db}' → ${GCS_DUMP_PATH}"
  gcloud sql export sql "${SOURCE_INSTANCE}" "${GCS_DUMP_PATH}" \
    --project="${PROJECT_ID}" \
    --database="${db}" \
    --offload
  success "Export complete: ${db}"

  info "Downloading '${db}' dump …"
  gcloud storage cp "${GCS_DUMP_PATH}" "${LOCAL_DUMP_PATH}"
  success "Downloaded: ${LOCAL_DUMP_PATH}  ($(du -sh "${LOCAL_DUMP_PATH}" | cut -f1))"
done

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Export complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo
echo "Dumps saved to: ${LOCAL_DUMP_SUBDIR}/"
ls -lh "${LOCAL_DUMP_SUBDIR}/"
echo
echo "Next steps:"
echo "  1. SCP the dump(s) to your target VM:"
echo "     scp ${LOCAL_DUMP_SUBDIR}/*.sql.gz user@VM_IP:/home/user/"
echo "  2. SSH into the VM and run vm-import.sh for each dump:"
echo "     bash vm-import.sh"
echo "     (copy scripts/migration/gcp/vm-import.sh to the VM first)"
