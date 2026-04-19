#!/usr/bin/env bash
#
# vm-import.sh  —  VM machine script
#
# Restores Cloud SQL dump(s) (plain SQL, gzip-compressed) into an already-running
# PostgreSQL Docker container on this VM.
#
# Usage (run this INSIDE the target Compute VM):
#   bash vm-import.sh
#
# Modes:
#   1) All databases — point at the dump directory; DB name is inferred from
#      each filename (e.g. epiic-events.sql.gz → database 'epiic-events').
#      Credentials are prompted once and applied to every database.
#   2) Single database — point at one .sql.gz file; DB name prompted manually.
#
set -euo pipefail

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

# ── Restore a single database ─────────────────────────────────────────────────
# Usage: restore_db <dump_file> <db_name>
restore_db() {
  local dump_file="$1"
  local db_name="$2"

  echo
  echo -e "${YELLOW}── Restoring: ${db_name} ─────────────────────────────────${NC}"

  # Create user (idempotent)
  USER_EXISTS=$(${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';")
  if [[ "$USER_EXISTS" == "1" ]]; then
    warn "User '${DB_USER}' already exists — skipping creation."
  else
    ${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
      psql -U postgres -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';"
    success "User '${DB_USER}' created."
  fi

  # Create database (idempotent)
  DB_EXISTS=$(${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';")
  if [[ "$DB_EXISTS" == "1" ]]; then
    warn "Database '${db_name}' already exists — skipping creation."
  else
    ${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
      psql -U postgres -c "CREATE DATABASE \"${db_name}\" OWNER \"${DB_USER}\";"
    success "Database '${db_name}' created."
  fi

  ${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -c \
    "GRANT ALL PRIVILEGES ON DATABASE \"${db_name}\" TO \"${DB_USER}\";" &>/dev/null

  # Restore
  info "Restoring dump … (may take several minutes)"
  warn "Warnings about missing Cloud SQL roles are safe to ignore."
  gunzip -c "${dump_file}" | \
    ${DOCKER_CMD} exec -i \
      -e PGPASSWORD="${POSTGRES_PASSWORD}" \
      "${CONTAINER_NAME}" \
      psql -U postgres -d "${db_name}" \
      --set ON_ERROR_STOP=off \
      2>&1 | grep -v "^ERROR:  role\|^ERROR:  must be member\|^ERROR:  permission denied for schema\|^NOTICE:" \
      || true
  success "Restore complete."

  # Grant permissions
  ${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -d "${db_name}" -c \
    "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";
     GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"${DB_USER}\";
     GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"${DB_USER}\";
     ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"${DB_USER}\";
     ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${DB_USER}\";" \
    &>/dev/null
  success "Permissions granted."

  # Sanity check
  DB_SIZE=$(${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -d "${db_name}" -tAc \
    "SELECT pg_size_pretty(pg_database_size(current_database()));")
  TABLE_COUNT=$(${DOCKER_CMD} exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -d "${db_name}" -tAc \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema NOT IN ('pg_catalog','information_schema');")
  echo "  Size: ${DB_SIZE}   Tables: ${TABLE_COUNT}"
}

# ── Dependency check ──────────────────────────────────────────────────────────
command -v docker &>/dev/null || die "'docker' is not installed or not in PATH."

if docker info &>/dev/null 2>&1; then
  DOCKER_CMD="docker"
else
  DOCKER_CMD="sudo docker"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  Cloud SQL → Docker PostgreSQL Migration (VM Import)  ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo
echo "This script runs INSIDE the target Compute VM."
echo "Assumes the PostgreSQL Docker container is already up and running."
echo "Answer each prompt — press Enter to accept a default where shown."
echo

# ── Import scope ──────────────────────────────────────────────────────────────
echo -e "${CYAN}?${NC} Import scope:"
echo "    1) All databases  (directory of .sql.gz files)"
echo "    2) Single database (one .sql.gz file)"
read -r -p "$(echo -e "${CYAN}?${NC} Choice [1/2]: ")" IMPORT_SCOPE_CHOICE

case "${IMPORT_SCOPE_CHOICE}" in
  1) IMPORT_SCOPE="all" ;;
  2) IMPORT_SCOPE="single" ;;
  *) die "Invalid choice '${IMPORT_SCOPE_CHOICE}'. Enter 1 or 2." ;;
esac

# ── Gather inputs ─────────────────────────────────────────────────────────────
echo
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  echo -e "${YELLOW}── Dump directory ───────────────────────────────────────${NC}"
  prompt DUMP_DIR "Full path to the directory containing .sql.gz dumps"
  [[ -d "${DUMP_DIR}" ]] || die "Directory not found: ${DUMP_DIR}"

  DUMP_FILES=()
  while IFS= read -r f; do
    DUMP_FILES+=("$f")
  done < <(find "${DUMP_DIR}" -maxdepth 1 -name "*.sql.gz" | sort)

  [[ ${#DUMP_FILES[@]} -gt 0 ]] || die "No .sql.gz files found in: ${DUMP_DIR}"
  info "Found ${#DUMP_FILES[@]} dump file(s):"
  for f in "${DUMP_FILES[@]}"; do
    echo "    $(basename "${f}")  ($(du -sh "${f}" | cut -f1))"
  done
else
  echo -e "${YELLOW}── Dump file ────────────────────────────────────────────${NC}"
  prompt DUMP_FILE "Full path to the .sql.gz dump file"
  [[ -f "${DUMP_FILE}" ]] || die "File not found: ${DUMP_FILE}"
  info "Dump file: ${DUMP_FILE}  ($(du -sh "${DUMP_FILE}" | cut -f1))"

  echo
  echo -e "${YELLOW}── Database name ────────────────────────────────────────${NC}"
  prompt DB_NAME "Target database name"
fi

echo
echo -e "${YELLOW}── PostgreSQL Docker container ──────────────────────────${NC}"
prompt CONTAINER_NAME    "Running Docker container name"
prompt POSTGRES_PASSWORD "postgres superuser password" "" "true"

echo
echo -e "${YELLOW}── App user credentials (applied to all databases) ──────${NC}"
prompt DB_USER     "Database user for the application"
prompt DB_PASSWORD "Database user password" "" "true"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Summary ──────────────────────────────────────────────${NC}"
echo "  Container  : ${CONTAINER_NAME}"
echo "  DB user    : ${DB_USER}"
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  echo "  Dump dir   : ${DUMP_DIR}"
  echo "  Databases  : ${#DUMP_FILES[@]} (inferred from filenames)"
else
  echo "  Dump file  : ${DUMP_FILE}"
  echo "  Database   : ${DB_NAME}"
fi
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Verify container ──────────────────────────────────────────────────────────
info "Checking container '${CONTAINER_NAME}' …"
CONTAINER_STATE=$(${DOCKER_CMD} inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null \
  || die "Container '${CONTAINER_NAME}' not found. Is it running?")
[[ "$CONTAINER_STATE" == "running" ]] \
  || die "Container '${CONTAINER_NAME}' is '${CONTAINER_STATE}', expected 'running'."
success "Container is running."

info "Verifying PostgreSQL is accepting connections …"
${DOCKER_CMD} exec "${CONTAINER_NAME}" pg_isready -U postgres &>/dev/null \
  || die "PostgreSQL inside '${CONTAINER_NAME}' is not ready."
success "PostgreSQL is ready."

# ── Run restore(s) ────────────────────────────────────────────────────────────
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  for dump_file in "${DUMP_FILES[@]}"; do
    db_name=$(basename "${dump_file}" .sql.gz)
    restore_db "${dump_file}" "${db_name}"
  done
else
  restore_db "${DUMP_FILE}" "${DB_NAME}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Import complete!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  echo "Restored ${#DUMP_FILES[@]} database(s) into container '${CONTAINER_NAME}'."
else
  echo "Test connection:"
  echo "  PGPASSWORD='${DB_PASSWORD}' psql -h 127.0.0.1 -U ${DB_USER} -d ${DB_NAME}"
fi
