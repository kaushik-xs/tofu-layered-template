#!/usr/bin/env bash
#
# list-dbs.sh  —  LOCAL machine script
#
# Lists all PostgreSQL databases and the roles/users that have privileges
# on each database, from a Docker container running on a GCP Compute Engine VM.
#
# Usage (run this on your LOCAL machine):
#   ./scripts/migration/gcp/list-dbs.sh
#
# Connection types:
#   direct — plain SSH using an IP address and private key
#   iap    — gcloud compute ssh with --tunnel-through-iap (no public IP needed)
#
# What this script does:
#   1.  Loads saved values from config file (shared with create-app-db.sh)
#   2.  Prompts for connection type (direct SSH or IAP tunnel)
#   3.  Prompts for all required values, showing previous answers as defaults
#   4.  Verifies connectivity to the VM
#   5.  Verifies the Docker container is running and PostgreSQL is accepting connections
#   6.  Lists all databases with owner and size
#   7.  For each non-system database, lists roles with their privileges
#
set -euo pipefail

# ── Config file ───────────────────────────────────────────────────────────────
CONF_DIR="${HOME}/.config/pg-migration"
CONF_FILE="${CONF_DIR}/create-app-db.conf"   # reuse same config as create-app-db.sh

PREV_CONNECTION_TYPE=""
PREV_VM_NAME=""
PREV_VM_ZONE=""
PREV_PROJECT_ID=""
PREV_VM_USER=""
PREV_VM_IP=""
PREV_VM_SSH_KEY=""
PREV_CONTAINER_NAME=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
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
echo -e "${CYAN}  List PostgreSQL Databases + Users                   ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo
echo "This script runs on your LOCAL machine."
echo "It connects to a GCP Compute Engine VM to list databases and users."
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

# ── Step 4 — Verify connectivity ──────────────────────────────────────────────
echo
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

# ── Step 5 — Verify container ────────────────────────────────────────────────
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

# ── Step 6 — List all databases ───────────────────────────────────────────────
echo
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${YELLOW}  All Databases${NC}"
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════${NC}"
echo

vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
  psql -U postgres -c \
  "SELECT
     datname        AS \"Database\",
     pg_catalog.pg_get_userbyid(datdba) AS \"Owner\",
     pg_catalog.pg_size_pretty(pg_catalog.pg_database_size(datname)) AS \"Size\",
     datcollate     AS \"Collation\",
     datctype       AS \"Ctype\"
   FROM pg_database
   ORDER BY datname;"

# ── Step 7 — For each non-system database, list roles and privileges ──────────
echo
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${YELLOW}  Roles & Privileges Per Database${NC}"
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════${NC}"

DATABASES=$(vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
  psql -U postgres -tAc \
  "SELECT datname FROM pg_database
   WHERE datname NOT IN ('template0','template1','postgres')
   ORDER BY datname;")

if [[ -z "${DATABASES}" ]]; then
  warn "No user-created databases found."
else
  while IFS= read -r db; do
    echo
    echo -e "${CYAN}── Database: ${BOLD}${db}${NC}"
    echo

    # Roles with database-level ACL entries
    vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
      psql -U postgres -d "${db}" -c \
      "SELECT
         r.rolname          AS \"Role\",
         r.rolsuper         AS \"Superuser\",
         r.rolinherit       AS \"Inherit\",
         r.rolcreaterole    AS \"CreateRole\",
         r.rolcreatedb      AS \"CreateDB\",
         r.rolcanlogin      AS \"Login\",
         ARRAY(
           SELECT b.rolname
           FROM pg_catalog.pg_auth_members m
           JOIN pg_catalog.pg_roles b ON m.roleid = b.oid
           WHERE m.member = r.oid
         )                  AS \"MemberOf\"
       FROM pg_catalog.pg_roles r
       WHERE r.rolname NOT LIKE 'pg_%'
       ORDER BY r.rolname;"

    # Explicit CONNECT / GRANT entries on this database
    echo -e "  ${YELLOW}Database-level ACLs:${NC}"
    vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
      psql -U postgres -tAc \
      "SELECT datacl FROM pg_database WHERE datname='${db}';" \
      | tr ',' '\n' | tr -d '{}' | grep -v '^$' \
      | awk -F= '{printf "    %-30s  privileges: %s\n", $1, $2}' || true

  done <<< "${DATABASES}"
fi

# ── Step 8 — All roles overview ───────────────────────────────────────────────
echo
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${YELLOW}  All PostgreSQL Roles (Cluster-Wide)${NC}"
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════${NC}"
echo

vm_docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
  psql -U postgres -c \
  "SELECT
     rolname       AS \"Role\",
     rolsuper      AS \"Super\",
     rolcreatedb   AS \"CreateDB\",
     rolcreaterole AS \"CreateRole\",
     rolcanlogin   AS \"Login\",
     rolconnlimit  AS \"ConnLimit\",
     rolvaliduntil AS \"ValidUntil\"
   FROM pg_roles
   WHERE rolname NOT LIKE 'pg_%'
   ORDER BY rolcanlogin DESC, rolname;"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Done.${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
