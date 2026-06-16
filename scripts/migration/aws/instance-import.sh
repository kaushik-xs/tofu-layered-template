#!/usr/bin/env bash
#
# instance-import.sh  —  LOCAL machine script
#
# SCPs PostgreSQL dump(s) to an AWS EC2 instance and restores them into
# an already-running PostgreSQL Docker container on that instance.
#
# Usage (run this on your LOCAL machine):
#   ./scripts/migration/aws/instance-import.sh
#
# Connection types:
#   direct  — plain SSH using a reachable IP and private key
#   bastion — SSH through a public jump host (ProxyJump) to an instance that
#             lives in a private subnet with no public IP
#
# Import modes:
#   all    — point at the local dump directory produced by rds-export.sh;
#            DB name is inferred from each filename (file1.sql.gz → 'file1').
#            Credentials are prompted once and applied to every database.
#   single — point at one local .sql.gz file; DB name entered manually.
#
# Previous values are saved to ~/.config/pg-migration/aws-instance-import.conf and
# used as defaults on subsequent runs. Passwords are never saved.
#
# What this script does:
#   1.  Loads saved values from config file (if present)
#   2.  Prompts for connection type (direct SSH or bastion jump)
#   3.  Prompts for import scope (all databases or single)
#   4.  Prompts for all required values, showing previous answers as defaults
#   5.  Saves non-secret values to config file on confirmation
#   6.  Verifies connectivity to the instance
#   7.  Verifies the Docker container is running and PostgreSQL is accepting connections
#   8.  Creates a temporary staging directory on the instance
#   For each database:
#   9.  Copies the dump file from local machine to the instance staging directory
#   10. Creates the application user on the container (idempotent)
#   11. Drops the target database if it exists (clean import), then recreates it
#   12. Grants connect privileges on the database
#   13. Restores the dump on the instance: gunzip | docker exec psql
#   14. Grants schema, table, and sequence permissions to the application user
#   15. Runs a sanity check (database size + table count)
#   16. Removes the dump file from the instance staging directory
#
set -euo pipefail

# ── Config file ───────────────────────────────────────────────────────────────
CONF_DIR="${HOME}/.config/pg-migration"
CONF_FILE="${CONF_DIR}/aws-instance-import.conf"

PREV_CONNECTION_TYPE=""
PREV_IMPORT_SCOPE=""
PREV_DUMP_DIR=""
PREV_DUMP_FILE=""
PREV_DB_NAME=""
PREV_INSTANCE_IP=""
PREV_INSTANCE_USER=""
PREV_SSH_KEY=""
PREV_BASTION_HOST=""
PREV_BASTION_USER=""
PREV_BASTION_SSH_KEY=""
PREV_CONTAINER_NAME=""
PREV_DB_USER=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# pg-migration aws instance-import — last used values (auto-generated, do not commit)
# Passwords are never stored here.
PREV_CONNECTION_TYPE="${CONNECTION_TYPE}"
PREV_IMPORT_SCOPE="${IMPORT_SCOPE}"
PREV_DUMP_DIR="${DUMP_DIR:-}"
PREV_DUMP_FILE="${DUMP_FILE:-}"
PREV_DB_NAME="${DB_NAME:-}"
PREV_INSTANCE_IP="${INSTANCE_IP}"
PREV_INSTANCE_USER="${INSTANCE_USER}"
PREV_SSH_KEY="${SSH_KEY}"
PREV_BASTION_HOST="${BASTION_HOST:-}"
PREV_BASTION_USER="${BASTION_USER:-}"
PREV_BASTION_SSH_KEY="${BASTION_SSH_KEY:-}"
PREV_CONTAINER_NAME="${CONTAINER_NAME}"
PREV_DB_USER="${DB_USER}"
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

# ── Choice prompt helper ──────────────────────────────────────────────────────
prompt_choice() {
  local var_name="$1"
  local prev_val="$2"
  local num_opts="$3"
  shift 3

  local default_num=""
  local i=1
  for label in "$@"; do
    echo "    ${i}) ${label}"
    i=$((i + 1))
  done

  i=1
  for label in "$@"; do
    local opt_key
    opt_key=$(echo "${label}" | awk '{print $1}')
    if [[ "${opt_key}" == "${prev_val}" ]]; then
      default_num="${i}"
      break
    fi
    i=$((i + 1))
  done

  local display="Choice [1/${num_opts}]"
  [[ -n "${default_num}" ]] && display="Choice [${default_num}]"

  local choice=""
  read -r -p "$(echo -e "${CYAN}?${NC} ${display}: ")" choice
  [[ -z "${choice}" && -n "${default_num}" ]] && choice="${default_num}"
  [[ -z "${choice}" ]] && die "A choice is required."

  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || \
     [[ "${choice}" -lt 1 ]] || [[ "${choice}" -gt "${num_opts}" ]]; then
    die "Invalid choice '${choice}'. Enter a number between 1 and ${num_opts}."
  fi

  printf -v "$var_name" '%s' "${choice}"
}

# ── Connection helpers ────────────────────────────────────────────────────────
vm_ssh() {
  if [[ "${CONNECTION_TYPE}" == "bastion" ]]; then
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
      -o ProxyCommand="ssh -i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=accept-new -W %h:%p ${BASTION_USER}@${BASTION_HOST}" \
      "${INSTANCE_USER}@${INSTANCE_IP}" "$@"
  else
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
      "${INSTANCE_USER}@${INSTANCE_IP}" "$@"
  fi
}

vm_scp() {
  local local_file="$1"
  local remote_path="$2"
  if [[ "${CONNECTION_TYPE}" == "bastion" ]]; then
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
      -o ProxyCommand="ssh -i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=accept-new -W %h:%p ${BASTION_USER}@${BASTION_HOST}" \
      "${local_file}" "${INSTANCE_USER}@${INSTANCE_IP}:${remote_path}"
  else
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
      "${local_file}" "${INSTANCE_USER}@${INSTANCE_IP}:${remote_path}"
  fi
}

vm_docker() {
  local quoted=""
  for arg in "$@"; do
    quoted="${quoted} $(printf '%q' "${arg}")"
  done
  vm_ssh "${REMOTE_DOCKER_CMD}${quoted}"
}

# ── Restore a single database ─────────────────────────────────────────────────
# Usage: restore_db <local_dump_file> <db_name>
restore_db() {
  local local_dump="$1"
  local db_name="$2"
  local remote_dump="${VM_STAGING_DIR}/$(basename "${local_dump}")"

  echo
  echo -e "${YELLOW}── Restoring: ${db_name} ─────────────────────────────────${NC}"

  # Prompt for app user credentials for this specific database
  prompt DB_USER     "  App user for '${db_name}'" "${PREV_DB_USER}"
  prompt DB_PASSWORD "  Password for '${DB_USER}'" "" "true"

  # Step 9 — Copy dump to instance
  info "Copying dump to instance …"
  vm_scp "${local_dump}" "${remote_dump}"
  success "Dump on instance: ${remote_dump}"

  # Step 10 — Create user (idempotent)
  info "Creating user '${DB_USER}' …"
  USER_EXISTS=$(vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';" 2>/dev/null \
    | tr -d '[:space:]' || true)
  if [[ "$USER_EXISTS" == "1" ]]; then
    warn "User '${DB_USER}' already exists — skipping."
  else
    vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
      psql -U postgres -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';"
    success "User '${DB_USER}' created."
  fi

  # Step 11 — Drop (if exists) and recreate database for a clean import
  info "Checking database '${db_name}' …"
  DB_EXISTS=$(vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';" 2>/dev/null \
    | tr -d '[:space:]' || true)
  if [[ "$DB_EXISTS" == "1" ]]; then
    warn "Database '${db_name}' exists — dropping for a clean import …"
    # Terminate any open connections before dropping
    vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
      psql -U postgres -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${db_name}' AND pid <> pg_backend_pid();" \
      > /dev/null
    vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
      psql -U postgres -c "DROP DATABASE \"${db_name}\";"
    success "Database '${db_name}' dropped."
  fi
  vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -c "CREATE DATABASE \"${db_name}\" OWNER \"${DB_USER}\";"
  success "Database '${db_name}' created."

  # Step 12 — Grant connect
  vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -c \
    "GRANT ALL PRIVILEGES ON DATABASE \"${db_name}\" TO \"${DB_USER}\";" \
    > /dev/null

  # Step 13 — Restore (decompress and pipe into psql, all on the instance)
  info "Restoring dump … (may take several minutes)"
  warn "Warnings about missing managed-service roles are safe to ignore."
  vm_ssh "gunzip -c '${remote_dump}' | \
    ${REMOTE_DOCKER_CMD} exec -i \
      -e PGPASSWORD='${POSTGRES_PASSWORD}' \
      '${CONTAINER_NAME}' \
      psql -U postgres -d '${db_name}' --set ON_ERROR_STOP=off 2>&1 | \
    grep -v '^ERROR:  role\|^ERROR:  must be member\|^ERROR:  permission denied for schema\|^NOTICE:' \
    || true"
  success "Restore complete."

  # Step 14 — Grant schema/table/sequence permissions
  vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -d "${db_name}" -c \
    "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";
     GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"${DB_USER}\";
     GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"${DB_USER}\";
     ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"${DB_USER}\";
     ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${DB_USER}\";" \
    > /dev/null
  success "Permissions granted."

  # Step 15 — Sanity check
  DB_SIZE=$(vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -d "${db_name}" -tAc \
    "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null \
    | tr -d '[:space:]' || true)
  TABLE_COUNT=$(vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -d "${db_name}" -tAc \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema NOT IN ('pg_catalog','information_schema');" 2>/dev/null \
    | tr -d '[:space:]' || true)
  echo "  Size: ${DB_SIZE}   Tables: ${TABLE_COUNT}"

  # Step 16 — Remove dump from instance
  vm_ssh "rm -f '${remote_dump}'"
  info "Removed dump from instance staging directory."
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in ssh scp; do
  command -v "$cmd" &>/dev/null || die "'${cmd}' is not installed or not in PATH."
done

# ── Step 1 — Load saved config ────────────────────────────────────────────────
load_config

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  PostgreSQL → Docker Migration (EC2 Instance Import) ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo
echo "This script runs on your LOCAL machine."
echo "It connects to an AWS EC2 instance to drive the restore."
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Step 2 — Connection type ──────────────────────────────────────────────────
echo -e "${CYAN}?${NC} Instance connection type:"
prompt_choice CONN_CHOICE "${PREV_CONNECTION_TYPE}" 2 \
  "direct   Direct SSH    (reachable IP + private key)" \
  "bastion  Bastion jump  (SSH ProxyJump through a public host)"

case "${CONN_CHOICE}" in
  1) CONNECTION_TYPE="direct" ;;
  2) CONNECTION_TYPE="bastion" ;;
esac

# ── Step 3 — Import scope ─────────────────────────────────────────────────────
echo
echo -e "${CYAN}?${NC} Import scope:"
prompt_choice SCOPE_CHOICE "${PREV_IMPORT_SCOPE}" 2 \
  "all     All databases   (local directory of .sql.gz files)" \
  "single  Single database (one local .sql.gz file)"

case "${SCOPE_CHOICE}" in
  1) IMPORT_SCOPE="all" ;;
  2) IMPORT_SCOPE="single" ;;
esac

# ── Step 4 — Gather inputs ────────────────────────────────────────────────────

# Declare all optional variables upfront to avoid unbound errors
DUMP_DIR=""; DUMP_FILE=""; DB_NAME=""
BASTION_HOST=""; BASTION_USER=""; BASTION_SSH_KEY=""
DB_USER=""; DB_PASSWORD=""
DUMP_FILES=()
REMOTE_DOCKER_CMD="docker"   # may be updated to "sudo docker" after SSH check

echo
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  echo -e "${YELLOW}── Local dump directory ─────────────────────────────────${NC}"
  prompt DUMP_DIR "Path to the local directory containing .sql.gz dumps" "${PREV_DUMP_DIR}"
  [[ -d "${DUMP_DIR}" ]] || die "Directory not found: ${DUMP_DIR}"

  while IFS= read -r f; do
    DUMP_FILES+=("$f")
  done < <(find "${DUMP_DIR}" -maxdepth 1 -name "*.sql.gz" | sort)

  [[ ${#DUMP_FILES[@]} -gt 0 ]] || die "No .sql.gz files found in: ${DUMP_DIR}"
  info "Found ${#DUMP_FILES[@]} dump file(s):"
  for f in "${DUMP_FILES[@]}"; do
    echo "    $(basename "${f}")  ($(du -sh "${f}" | cut -f1))"
  done
else
  echo -e "${YELLOW}── Local dump file ──────────────────────────────────────${NC}"
  prompt DUMP_FILE "Path to the local .sql.gz dump file" "${PREV_DUMP_FILE}"
  [[ -f "${DUMP_FILE}" ]] || die "File not found: ${DUMP_FILE}"
  info "Dump: ${DUMP_FILE}  ($(du -sh "${DUMP_FILE}" | cut -f1))"

  echo
  echo -e "${YELLOW}── Database name ────────────────────────────────────────${NC}"
  prompt DB_NAME "Target database name" "${PREV_DB_NAME}"
fi

echo
echo -e "${YELLOW}── EC2 instance ─────────────────────────────────────────${NC}"
prompt INSTANCE_IP   "EC2 instance IP (private IP if via bastion)" "${PREV_INSTANCE_IP}"
prompt INSTANCE_USER "EC2 SSH user"                                "${PREV_INSTANCE_USER:-ec2-user}"
prompt SSH_KEY       "Path to SSH private key for EC2"             "${PREV_SSH_KEY:-${HOME}/.ssh/id_rsa}"

if [[ "${CONNECTION_TYPE}" == "bastion" ]]; then
  echo
  echo -e "${YELLOW}── Bastion / jump host ──────────────────────────────────${NC}"
  prompt BASTION_HOST    "Bastion public host or IP"          "${PREV_BASTION_HOST}"
  prompt BASTION_USER    "Bastion SSH user"                   "${PREV_BASTION_USER:-ec2-user}"
  prompt BASTION_SSH_KEY "Path to SSH key for bastion"        "${PREV_BASTION_SSH_KEY:-${SSH_KEY}}"
  INSTANCE_LABEL="${INSTANCE_USER}@${INSTANCE_IP} via ${BASTION_USER}@${BASTION_HOST}"
else
  INSTANCE_LABEL="${INSTANCE_USER}@${INSTANCE_IP}"
fi

echo
echo -e "${YELLOW}── PostgreSQL Docker container ──────────────────────────${NC}"
prompt CONTAINER_NAME    "Running Docker container name" "${PREV_CONTAINER_NAME}"
prompt POSTGRES_PASSWORD "postgres superuser password"  "" "true"

VM_STAGING_DIR="/tmp/pg-migration"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Summary ──────────────────────────────────────────────${NC}"
echo "  Connection     : ${CONNECTION_TYPE}"
echo "  Instance       : ${INSTANCE_LABEL}"
echo "  Container       : ${CONTAINER_NAME}"
echo "  Staging dir    : ${VM_STAGING_DIR}"
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  echo "  Dump dir       : ${DUMP_DIR}"
  echo "  Databases      : ${#DUMP_FILES[@]} (app user prompted per database)"
else
  echo "  Dump file      : ${DUMP_FILE}"
  echo "  Database       : ${DB_NAME}  (app user prompted before restore)"
fi
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Step 6 — Verify connectivity ─────────────────────────────────────────────
info "Verifying connectivity to instance …"
vm_ssh "echo ok" > /dev/null || die "Cannot connect to instance. Check your connection details."
success "Instance connection confirmed."

info "Detecting Docker permissions on instance …"
if vm_ssh "docker info > /dev/null 2>&1"; then
  REMOTE_DOCKER_CMD="docker"
elif vm_ssh "sudo docker info > /dev/null 2>&1"; then
  REMOTE_DOCKER_CMD="sudo docker"
  warn "Docker requires sudo on this instance — using 'sudo docker' for all commands."
else
  die "Cannot access Docker on instance. Ensure Docker is installed and the user has access."
fi
success "Docker accessible via: ${REMOTE_DOCKER_CMD}"

# ── Step 7 — Verify container ────────────────────────────────────────────────
info "Checking container '${CONTAINER_NAME}' on instance …"
CONTAINER_STATE=$(vm_docker inspect -f "{{.State.Status}}" "${CONTAINER_NAME}" 2>/dev/null \
  | tr -d '[:space:]' || true)
if [[ -z "${CONTAINER_STATE}" ]]; then
  die "Container '${CONTAINER_NAME}' not found on instance. Check the container name."
fi
[[ "${CONTAINER_STATE}" == "running" ]] \
  || die "Container '${CONTAINER_NAME}' is '${CONTAINER_STATE}', expected 'running'."
success "Container is running."

info "Verifying PostgreSQL is accepting connections …"
vm_docker exec "${CONTAINER_NAME}" pg_isready -U postgres > /dev/null \
  || die "PostgreSQL inside '${CONTAINER_NAME}' is not ready."
success "PostgreSQL is ready."

# ── Step 8 — Create staging directory on instance ────────────────────────────
vm_ssh "mkdir -p '${VM_STAGING_DIR}'"
success "Staging directory ready: ${VM_STAGING_DIR}"

# ── Run restore(s) ────────────────────────────────────────────────────────────
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  for dump_file in "${DUMP_FILES[@]}"; do
    db_name=$(basename "${dump_file}" .sql.gz)
    restore_db "${dump_file}" "${db_name}"
    PREV_DB_USER="${DB_USER}"   # seed default for the next database
  done
else
  restore_db "${DUMP_FILE}" "${DB_NAME}"
fi

# ── Save config (after restores so DB_USER reflects the last used value) ──────
save_config
success "Saved values to ${CONF_FILE}"

# ── Cleanup staging dir ───────────────────────────────────────────────────────
vm_ssh "rmdir '${VM_STAGING_DIR}' 2>/dev/null || true"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Import complete!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
if [[ "${IMPORT_SCOPE}" == "all" ]]; then
  echo "Restored ${#DUMP_FILES[@]} database(s) into '${CONTAINER_NAME}' on ${INSTANCE_LABEL}."
else
  echo "Restored '${DB_NAME}' into '${CONTAINER_NAME}' on ${INSTANCE_LABEL}."
  echo
  echo "Test connection from the instance:"
  echo "  PGPASSWORD='${DB_PASSWORD}' psql -h 127.0.0.1 -U ${DB_USER} -d ${DB_NAME}"
fi
