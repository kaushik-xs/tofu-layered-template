#!/usr/bin/env bash
#
# create-app-db.sh  —  LOCAL machine script
#
# Creates an application database and user on a PostgreSQL Docker container
# running on an AWS EC2 instance, then grants all necessary privileges.
#
# Usage (run this on your LOCAL machine):
#   ./scripts/migration/aws/create-app-db.sh
#
# Connection types:
#   direct  — plain SSH using a reachable IP and private key
#   bastion — SSH through a public jump host (ProxyJump) to an instance that
#             lives in a private subnet with no public IP
#
# What this script does:
#   1.  Loads saved values from config file (if present)
#   2.  Prompts for connection type (direct SSH or bastion jump)
#   3.  Prompts for connection/container values, showing previous answers as defaults
#   4.  Reads the databases/users/passwords to create from a CSV file
#         CSV columns: db_name,db_user,db_password  (one database per line;
#         an optional header row and #-comment lines are skipped)
#   5.  Prints a summary of every database and asks for a single confirmation
#   6.  Saves non-secret values to config file
#   7.  Verifies connectivity to the instance
#   8.  Verifies the Docker container is running and PostgreSQL is accepting connections
#   9.  For each CSV row (idempotent):
#         - Creates the application user
#         - Creates the application database owned by the app user
#         - Grants CONNECT + all privileges on the database to the app user
#         - Grants schema, table, and sequence permissions + sets default privileges
#   10. Prints a connection test command
#
set -euo pipefail

# ── Config file ───────────────────────────────────────────────────────────────
CONF_DIR="${HOME}/.config/pg-migration"
CONF_FILE="${CONF_DIR}/aws-create-app-db.conf"

PREV_CONNECTION_TYPE=""
PREV_INSTANCE_IP=""
PREV_INSTANCE_USER=""
PREV_SSH_KEY=""
PREV_BASTION_HOST=""
PREV_BASTION_USER=""
PREV_BASTION_SSH_KEY=""
PREV_CONTAINER_NAME=""
PREV_CSV_FILE=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# pg-migration aws create-app-db — last used values (auto-generated, do not commit)
# Passwords are never stored here.
PREV_CONNECTION_TYPE="${CONNECTION_TYPE}"
PREV_INSTANCE_IP="${INSTANCE_IP}"
PREV_INSTANCE_USER="${INSTANCE_USER}"
PREV_SSH_KEY="${SSH_KEY}"
PREV_BASTION_HOST="${BASTION_HOST:-}"
PREV_BASTION_USER="${BASTION_USER:-}"
PREV_BASTION_SSH_KEY="${BASTION_SSH_KEY:-}"
PREV_CONTAINER_NAME="${CONTAINER_NAME}"
PREV_CSV_FILE="${CSV_FILE}"
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
# vm_ssh: run a command on the EC2 instance. With 'bastion', the connection is
# tunnelled through a public jump host using SSH ProxyCommand (-W), so the
# instance itself needs no public IP. The bastion key is applied to the jump
# hop; the instance key to the final hop.
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

# vm_docker: used only for non-SQL docker commands (inspect, pg_isready, etc.)
# Avoids use for psql -c to prevent quoting issues — use pg_exec/pg_query instead.
vm_docker() {
  local quoted=""
  for arg in "$@"; do
    quoted="${quoted} $(printf '%q' "${arg}")"
  done
  vm_ssh "${REMOTE_DOCKER_CMD}${quoted}"
}

# pg_exec: pipe SQL into psql via stdin (docker exec -i) to avoid all -c quoting issues.
# Usage: pg_exec <database> <sql>
pg_exec() {
  local database="$1"
  local sql="$2"
  local esc_pass esc_container esc_db
  esc_pass=$(printf '%q' "${POSTGRES_PASSWORD}")
  esc_container=$(printf '%q' "${CONTAINER_NAME}")
  esc_db=$(printf '%q' "${database}")
  printf '%s\n' "${sql}" | \
    vm_ssh "${REMOTE_DOCKER_CMD} exec -i -e PGPASSWORD=${esc_pass} ${esc_container} \
      psql -U postgres -d ${esc_db} --set ON_ERROR_STOP=on -q"
}

# pg_query: pipe SQL into psql and return trimmed scalar output.
# Usage: result=$(pg_query <database> <sql>)
pg_query() {
  local database="$1"
  local sql="$2"
  local esc_pass esc_container esc_db
  esc_pass=$(printf '%q' "${POSTGRES_PASSWORD}")
  esc_container=$(printf '%q' "${CONTAINER_NAME}")
  esc_db=$(printf '%q' "${database}")
  printf '%s\n' "${sql}" | \
    vm_ssh "${REMOTE_DOCKER_CMD} exec -i -e PGPASSWORD=${esc_pass} ${esc_container} \
      psql -U postgres -d ${esc_db} -tA" \
    2>/dev/null | tr -d '[:space:]' || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in ssh; do
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
echo "It connects to an AWS EC2 instance to create the database."
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

# ── Step 3 — Gather inputs ────────────────────────────────────────────────────
BASTION_HOST=""; BASTION_USER=""; BASTION_SSH_KEY=""
REMOTE_DOCKER_CMD="docker"

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
prompt CONTAINER_NAME    "Running Docker container name"  "${PREV_CONTAINER_NAME}"
prompt POSTGRES_PASSWORD "postgres superuser password"    "" "true"

echo
echo -e "${YELLOW}── Application databases (CSV) ──────────────────────────${NC}"
echo "  CSV columns: db_name,db_user,db_password (one database per line)."
echo "  A header row named 'db_name,db_user,db_password' is skipped if present."
prompt CSV_FILE "Path to CSV file" "${PREV_CSV_FILE}"

[[ -f "${CSV_FILE}" ]] || die "CSV file '${CSV_FILE}' not found."

# ── Parse CSV into parallel arrays ────────────────────────────────────────────
DB_NAMES=(); DB_USERS=(); DB_PASSWORDS=()
line_no=0
while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
  line_no=$((line_no + 1))
  # Strip trailing CR (Windows line endings) and surrounding whitespace.
  raw_line="${raw_line%$'\r'}"
  # Skip blank lines and comment lines.
  [[ -z "${raw_line//[[:space:]]/}" ]] && continue
  [[ "${raw_line}" =~ ^[[:space:]]*# ]] && continue

  IFS=',' read -r c_name c_user c_pass <<< "${raw_line}"
  # Trim whitespace around each field.
  c_name="${c_name#"${c_name%%[![:space:]]*}"}"; c_name="${c_name%"${c_name##*[![:space:]]}"}"
  c_user="${c_user#"${c_user%%[![:space:]]*}"}"; c_user="${c_user%"${c_user##*[![:space:]]}"}"

  # Skip a header row.
  if [[ "${c_name}" == "db_name" && "${c_user}" == "db_user" ]]; then
    continue
  fi

  [[ -z "${c_name}" || -z "${c_user}" || -z "${c_pass}" ]] \
    && die "CSV line ${line_no} is malformed. Expected: db_name,db_user,db_password"

  DB_NAMES+=("${c_name}"); DB_USERS+=("${c_user}"); DB_PASSWORDS+=("${c_pass}")
done < "${CSV_FILE}"

[[ "${#DB_NAMES[@]}" -gt 0 ]] || die "No database entries found in '${CSV_FILE}'."

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Summary ──────────────────────────────────────────────${NC}"
echo "  Connection  : ${CONNECTION_TYPE}"
echo "  Instance    : ${INSTANCE_LABEL}"
echo "  Container   : ${CONTAINER_NAME}"
echo "  CSV file    : ${CSV_FILE}"
echo "  Databases   : ${#DB_NAMES[@]}"
echo
printf "    %-30s %-30s %s\n" "DATABASE" "APP USER" "PASSWORD"
printf "    %-30s %-30s %s\n" "--------" "--------" "--------"
for i in "${!DB_NAMES[@]}"; do
  printf "    %-30s %-30s %s\n" "${DB_NAMES[$i]}" "${DB_USERS[$i]}" "********"
done
echo

read -r -p "$(echo -e "${CYAN}?${NC} Create the ${#DB_NAMES[@]} database(s) above? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Step 5 — Verify connectivity ─────────────────────────────────────────────
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

# ── Step 6 — Verify container ────────────────────────────────────────────────
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

# ── Per-database provisioning (idempotent) ───────────────────────────────────
# create_app_db <db_name> <db_user> <db_password>
# Runs the user + database + privilege steps for one CSV entry.
create_app_db() {
  local DB_NAME="$1"
  local DB_USER="$2"
  local DB_PASSWORD="$3"

  # Skip the whole entry if the database already exists.
  info "Checking database '${DB_NAME}' …"
  local DB_EXISTS
  DB_EXISTS=$(pg_query "postgres" \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';")
  if [[ "${DB_EXISTS}" == "1" ]]; then
    warn "Database '${DB_NAME}' already exists — skipping this entry."
    return 0
  fi

  # Create application user (idempotent).
  info "Creating user '${DB_USER}' …"
  local USER_EXISTS
  USER_EXISTS=$(pg_query "postgres" \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';")
  if [[ "${USER_EXISTS}" == "1" ]]; then
    warn "User '${DB_USER}' already exists — updating password."
    pg_exec "postgres" "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';"
    success "Password updated for '${DB_USER}'."
  else
    pg_exec "postgres" "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';"
    success "User '${DB_USER}' created."
  fi

  # Create database owned by the app user.
  pg_exec "postgres" "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";"
  success "Database '${DB_NAME}' created."

  # Grant database-level privileges.
  info "Granting database privileges to '${DB_USER}' …"
  pg_exec "postgres" "GRANT CONNECT ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";"
  pg_exec "postgres" "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";"
  success "Database privileges granted."

  # Grant schema / table / sequence privileges.
  info "Granting schema and object privileges …"
  pg_exec "${DB_NAME}" "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";"
  pg_exec "${DB_NAME}" "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"${DB_USER}\";"
  pg_exec "${DB_NAME}" "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"${DB_USER}\";"
  pg_exec "${DB_NAME}" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"${DB_USER}\";"
  pg_exec "${DB_NAME}" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${DB_USER}\";"
  success "Schema and object privileges granted."
}

# ── Steps 7–10 — Provision every database from the CSV ───────────────────────
for i in "${!DB_NAMES[@]}"; do
  echo
  echo -e "${CYAN}── [$((i + 1))/${#DB_NAMES[@]}] ${DB_NAMES[$i]} ─────────────────────────${NC}"
  create_app_db "${DB_NAMES[$i]}" "${DB_USERS[$i]}" "${DB_PASSWORDS[$i]}"
done

# ── Save config ───────────────────────────────────────────────────────────────
save_config
success "Saved values to ${CONF_FILE}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Database setup complete! (${#DB_NAMES[@]} database(s))${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
printf "  %-30s %s\n" "DATABASE" "APP USER"
for i in "${!DB_NAMES[@]}"; do
  printf "  %-30s %s\n" "${DB_NAMES[$i]}" "${DB_USERS[$i]}"
done
echo
echo "Test a connection from the instance:"
echo "  PGPASSWORD='<password>' psql -h 127.0.0.1 -U ${DB_USERS[0]} -d ${DB_NAMES[0]}"
