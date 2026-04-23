#!/usr/bin/env bash
#
# create-app-db.sh  —  LOCAL machine script
#
# Creates an application database and user on a PostgreSQL Docker container
# running on a GCP Compute Engine VM, then grants all necessary privileges.
#
# Usage (run this on your LOCAL machine):
#   ./scripts/migration/gcp/create-app-db.sh
#
# Connection types:
#   direct — plain SSH using an IP address and private key
#   iap    — gcloud compute ssh with --tunnel-through-iap (no public IP needed)
#
# What this script does:
#   1.  Loads saved values from config file (if present)
#   2.  Prompts for connection type (direct SSH or IAP tunnel)
#   3.  Prompts for all required values, showing previous answers as defaults
#   4.  Saves non-secret values to config file on confirmation
#   5.  Verifies connectivity to the VM
#   6.  Verifies the Docker container is running and PostgreSQL is accepting connections
#   7.  Creates the application user (idempotent)
#   8.  Creates the application database owned by the app user (idempotent)
#   9.  Grants CONNECT + all privileges on the database to the app user
#   10. Grants schema, table, and sequence permissions + sets default privileges
#   11. Prints a connection test command
#
set -euo pipefail

# ── Config file ───────────────────────────────────────────────────────────────
CONF_DIR="${HOME}/.config/pg-migration"
CONF_FILE="${CONF_DIR}/create-app-db.conf"

PREV_CONNECTION_TYPE=""
PREV_VM_NAME=""
PREV_VM_ZONE=""
PREV_PROJECT_ID=""
PREV_VM_USER=""
PREV_VM_IP=""
PREV_VM_SSH_KEY=""
PREV_CONTAINER_NAME=""
PREV_DB_NAME=""
PREV_DB_USER=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# pg-migration create-app-db — last used values (auto-generated, do not commit)
# Passwords are never stored here.
PREV_CONNECTION_TYPE="${CONNECTION_TYPE}"
PREV_VM_NAME="${VM_NAME:-}"
PREV_VM_ZONE="${VM_ZONE:-}"
PREV_PROJECT_ID="${PROJECT_ID:-}"
PREV_VM_USER="${VM_USER:-}"
PREV_VM_IP="${VM_IP:-}"
PREV_VM_SSH_KEY="${VM_SSH_KEY:-}"
PREV_CONTAINER_NAME="${CONTAINER_NAME}"
PREV_DB_NAME="${DB_NAME}"
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
  if [[ "${CONNECTION_TYPE}" == "iap" ]]; then
    gcloud compute ssh --zone="${VM_ZONE}" "${VM_NAME}" \
      --tunnel-through-iap --project="${PROJECT_ID}" \
      --quiet -- "$@"
  else
    ssh -i "${VM_SSH_KEY}" -o StrictHostKeyChecking=accept-new \
      "${VM_USER}@${VM_IP}" "$@"
  fi
}

vm_docker() {
  local quoted=""
  for arg in "$@"; do
    quoted="${quoted} $(printf '%q' "${arg}")"
  done
  vm_ssh "${REMOTE_DOCKER_CMD}${quoted}"
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in ssh gcloud; do
  command -v "$cmd" &>/dev/null || die "'${cmd}' is not installed or not in PATH."
done

# ── Step 1 — Load saved config ────────────────────────────────────────────────
load_config

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  Create Application Database + User (PostgreSQL)     ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo
echo "This script runs on your LOCAL machine."
echo "It connects to a GCP Compute Engine VM to create the database."
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Step 2 — Connection type ──────────────────────────────────────────────────
echo -e "${CYAN}?${NC} VM connection type:"
prompt_choice CONN_CHOICE "${PREV_CONNECTION_TYPE}" 2 \
  "direct  Direct SSH     (public/internal IP + private key)" \
  "iap     IAP tunnel     (gcloud compute ssh --tunnel-through-iap)"

case "${CONN_CHOICE}" in
  1) CONNECTION_TYPE="direct" ;;
  2) CONNECTION_TYPE="iap" ;;
esac

# ── Step 3 — Gather inputs ────────────────────────────────────────────────────
VM_NAME=""; VM_ZONE=""; PROJECT_ID=""; VM_IP=""; VM_SSH_KEY=""
REMOTE_DOCKER_CMD="docker"

echo
echo -e "${YELLOW}── Compute Engine VM ────────────────────────────────────${NC}"
if [[ "${CONNECTION_TYPE}" == "iap" ]]; then
  prompt VM_NAME    "VM instance name"    "${PREV_VM_NAME}"
  prompt VM_ZONE    "VM zone"             "${PREV_VM_ZONE:-asia-south1-a}"
  prompt PROJECT_ID "GCP project ID"      "${PREV_PROJECT_ID}"
  prompt VM_USER    "VM SSH user"         "${PREV_VM_USER:-ubuntu}"
  VM_LABEL="${VM_NAME} (${VM_ZONE}) via IAP"
else
  prompt VM_IP      "VM external IP (or internal IP if same VPC)" "${PREV_VM_IP}"
  prompt VM_USER    "VM SSH user"         "${PREV_VM_USER:-ubuntu}"
  prompt VM_SSH_KEY "Path to SSH private key" "${PREV_VM_SSH_KEY:-${HOME}/.ssh/id_rsa}"
  VM_LABEL="${VM_USER}@${VM_IP}"
fi

echo
echo -e "${YELLOW}── PostgreSQL Docker container ──────────────────────────${NC}"
prompt CONTAINER_NAME    "Running Docker container name"  "${PREV_CONTAINER_NAME}"
prompt POSTGRES_PASSWORD "postgres superuser password"    "" "true"

echo
echo -e "${YELLOW}── Application database ─────────────────────────────────${NC}"
prompt DB_NAME     "Database name to create"             "${PREV_DB_NAME}"
prompt DB_USER     "Application username"                "${PREV_DB_USER}"
prompt DB_PASSWORD "Password for '${DB_USER}'"          "" "true"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Summary ──────────────────────────────────────────────${NC}"
echo "  Connection  : ${CONNECTION_TYPE}"
echo "  VM          : ${VM_LABEL}"
echo "  Container   : ${CONTAINER_NAME}"
echo "  Database    : ${DB_NAME}"
echo "  App user    : ${DB_USER}"
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Step 5 — Verify connectivity ─────────────────────────────────────────────
info "Verifying connectivity to VM …"
vm_ssh "echo ok" > /dev/null || die "Cannot connect to VM. Check your connection details."
success "VM connection confirmed."

info "Detecting Docker permissions on VM …"
if vm_ssh "docker info > /dev/null 2>&1"; then
  REMOTE_DOCKER_CMD="docker"
elif vm_ssh "sudo docker info > /dev/null 2>&1"; then
  REMOTE_DOCKER_CMD="sudo docker"
  warn "Docker requires sudo on this VM — using 'sudo docker' for all commands."
else
  die "Cannot access Docker on VM. Ensure Docker is installed and the user has access."
fi
success "Docker accessible via: ${REMOTE_DOCKER_CMD}"

# ── Step 6 — Verify container ────────────────────────────────────────────────
info "Checking container '${CONTAINER_NAME}' on VM …"
CONTAINER_STATE=$(vm_docker inspect -f "{{.State.Status}}" "${CONTAINER_NAME}" 2>/dev/null \
  | tr -d '[:space:]' || true)
if [[ -z "${CONTAINER_STATE}" ]]; then
  die "Container '${CONTAINER_NAME}' not found on VM. Check the container name."
fi
[[ "${CONTAINER_STATE}" == "running" ]] \
  || die "Container '${CONTAINER_NAME}' is '${CONTAINER_STATE}', expected 'running'."
success "Container is running."

info "Verifying PostgreSQL is accepting connections …"
vm_docker exec "${CONTAINER_NAME}" pg_isready -U postgres > /dev/null \
  || die "PostgreSQL inside '${CONTAINER_NAME}' is not ready."
success "PostgreSQL is ready."

# ── Step 7 — Create application user (idempotent) ────────────────────────────
info "Creating user '${DB_USER}' …"
USER_EXISTS=$(vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
  psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';" 2>/dev/null \
  | tr -d '[:space:]' || true)
if [[ "${USER_EXISTS}" == "1" ]]; then
  warn "User '${DB_USER}' already exists — updating password."
  vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" \
    > /dev/null
  success "Password updated for '${DB_USER}'."
else
  vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -c \
    "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" \
    > /dev/null
  success "User '${DB_USER}' created."
fi

# ── Step 8 — Create database (idempotent) ────────────────────────────────────
info "Checking database '${DB_NAME}' …"
DB_EXISTS=$(vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
  psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" 2>/dev/null \
  | tr -d '[:space:]' || true)
if [[ "${DB_EXISTS}" == "1" ]]; then
  warn "Database '${DB_NAME}' already exists — skipping creation."
else
  vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    psql -U postgres -c \
    "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";" \
    > /dev/null
  success "Database '${DB_NAME}' created."
fi

# ── Step 9 — Grant database-level privileges ──────────────────────────────────
info "Granting database privileges to '${DB_USER}' …"
vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
  psql -U postgres -c \
  "GRANT CONNECT ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";
   GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";" \
  > /dev/null
success "Database privileges granted."

# ── Step 10 — Grant schema / table / sequence privileges ─────────────────────
info "Granting schema and object privileges …"
vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
  psql -U postgres -d "${DB_NAME}" -c \
  "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";
   GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"${DB_USER}\";
   GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"${DB_USER}\";
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"${DB_USER}\";
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${DB_USER}\";" \
  > /dev/null
success "Schema and object privileges granted."

# ── Save config ───────────────────────────────────────────────────────────────
save_config
success "Saved values to ${CONF_FILE}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Database setup complete!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
echo "  Database : ${DB_NAME}"
echo "  User     : ${DB_USER}"
echo
echo "Test connection from the VM:"
echo "  PGPASSWORD='<password>' psql -h 127.0.0.1 -U ${DB_USER} -d ${DB_NAME}"
