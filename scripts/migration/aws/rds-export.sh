#!/usr/bin/env bash
#
# rds-export.sh  —  LOCAL machine script
#
# Exports a source PostgreSQL database (e.g. Amazon RDS) to local .sql.gz dumps
# using pg_dump. Output files are named <db>.sql.gz and are directly consumable
# by instance-import.sh.
#
# Usage:
#   ./scripts/migration/aws/rds-export.sh
#
# Connection types:
#   direct  — pg_dump connects straight to the RDS endpoint (reachable from here)
#   bastion — an SSH tunnel is opened through a public jump host and pg_dump
#             connects through a forwarded local port (for RDS in a private subnet)
#
# What this script does:
#   1. Prompts for connection type and all required values
#   2. (bastion) Opens an SSH local-forward tunnel to the RDS endpoint
#   3. Verifies connectivity with pg_isready
#   4. Resolves the database list (all user DBs, or a single named DB)
#   5. Runs pg_dump per database (plain SQL, gzip-compressed) into a local dir
#   6. Closes the tunnel on exit
#
# Note: pg_dump must be at least as new as the source server's major version.
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

# ── Choice prompt helper ──────────────────────────────────────────────────────
prompt_choice() {
  local var_name="$1"
  local num_opts="$2"
  shift 2

  local i=1
  for label in "$@"; do
    echo "    ${i}) ${label}"
    i=$((i + 1))
  done

  local choice=""
  read -r -p "$(echo -e "${CYAN}?${NC} Choice [1/${num_opts}]: ")" choice
  [[ -z "${choice}" ]] && die "A choice is required."

  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || \
     [[ "${choice}" -lt 1 ]] || [[ "${choice}" -gt "${num_opts}" ]]; then
    die "Invalid choice '${choice}'. Enter a number between 1 and ${num_opts}."
  fi

  printf -v "$var_name" '%s' "${choice}"
}

# ── Tunnel cleanup ────────────────────────────────────────────────────────────
TUNNEL_PID=""
cleanup() {
  if [[ -n "${TUNNEL_PID}" ]] && kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
    info "Closed SSH tunnel (pid ${TUNNEL_PID})."
  fi
}
trap cleanup EXIT

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in pg_dump psql; do
  command -v "$cmd" &>/dev/null || die "'${cmd}' is not installed or not in PATH."
done

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  RDS / PostgreSQL → Local Machine (Export) ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
echo "This script runs on your LOCAL machine."
echo "Answer each prompt — press Enter to accept a default where shown."
echo

# ── Connection type ───────────────────────────────────────────────────────────
echo -e "${CYAN}?${NC} Source connection type:"
prompt_choice CONN_CHOICE 2 \
  "direct   pg_dump connects straight to the RDS endpoint" \
  "bastion  pg_dump connects through an SSH tunnel (RDS in private subnet)"

case "${CONN_CHOICE}" in
  1) CONNECTION_TYPE="direct" ;;
  2) CONNECTION_TYPE="bastion" ;;
esac

# ── Gather inputs ─────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Source PostgreSQL (RDS) ──────────────────────────────${NC}"
prompt RDS_ENDPOINT "RDS endpoint hostname"
prompt RDS_PORT     "RDS port"            "5432"
prompt RDS_USER     "Master username"     "postgres"
prompt RDS_PASSWORD "Master password"     "" "true"

BASTION_HOST=""; BASTION_USER=""; BASTION_SSH_KEY=""; LOCAL_PORT=""
if [[ "${CONNECTION_TYPE}" == "bastion" ]]; then
  echo
  echo -e "${YELLOW}── Bastion / jump host ──────────────────────────────────${NC}"
  prompt BASTION_HOST    "Bastion public host or IP"
  prompt BASTION_USER    "Bastion SSH user"            "ec2-user"
  prompt BASTION_SSH_KEY "Path to SSH key for bastion" "${HOME}/.ssh/id_rsa"
  prompt LOCAL_PORT      "Local forward port"          "55432"
fi

echo
echo -e "${CYAN}?${NC} Export scope:"
echo "    1) All databases"
echo "    2) Single database"
read -r -p "$(echo -e "${CYAN}?${NC} Choice [1/2]: ")" EXPORT_SCOPE_CHOICE

DB_NAME=""
case "${EXPORT_SCOPE_CHOICE}" in
  1) EXPORT_SCOPE="all" ;;
  2) EXPORT_SCOPE="single"; prompt DB_NAME "Database name to export" ;;
  *) die "Invalid choice '${EXPORT_SCOPE_CHOICE}'. Enter 1 or 2." ;;
esac

echo
echo -e "${YELLOW}── Local paths ──────────────────────────────────────────${NC}"
prompt LOCAL_DUMP_DIR "Local directory to store the dump" "${HOME}/pg-migration"

# ── Derive connection target ──────────────────────────────────────────────────
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL_DUMP_SUBDIR="${LOCAL_DUMP_DIR}/${RDS_ENDPOINT%%.*}-${TIMESTAMP}"

if [[ "${CONNECTION_TYPE}" == "bastion" ]]; then
  PG_HOST="127.0.0.1"
  PG_PORT="${LOCAL_PORT}"
else
  PG_HOST="${RDS_ENDPOINT}"
  PG_PORT="${RDS_PORT}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Summary ──────────────────────────────────────────────${NC}"
echo "  Connection    : ${CONNECTION_TYPE}"
echo "  Source        : ${RDS_ENDPOINT}:${RDS_PORT} (user ${RDS_USER})"
[[ "${CONNECTION_TYPE}" == "bastion" ]] && \
  echo "  Bastion       : ${BASTION_USER}@${BASTION_HOST} → local 127.0.0.1:${LOCAL_PORT}"
if [[ "${EXPORT_SCOPE}" == "all" ]]; then
  echo "  Database      : (all user databases — exported individually)"
else
  echo "  Database      : ${DB_NAME}"
fi
echo "  Local dump dir: ${LOCAL_DUMP_SUBDIR}/"
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Open SSH tunnel (bastion only) ────────────────────────────────────────────
if [[ "${CONNECTION_TYPE}" == "bastion" ]]; then
  info "Opening SSH tunnel via ${BASTION_USER}@${BASTION_HOST} …"
  ssh -i "${BASTION_SSH_KEY}" -o StrictHostKeyChecking=accept-new \
    -o ExitOnForwardFailure=yes -N -f \
    -L "${LOCAL_PORT}:${RDS_ENDPOINT}:${RDS_PORT}" \
    "${BASTION_USER}@${BASTION_HOST}"
  # Find the backgrounded ssh we just started for this forward
  TUNNEL_PID=$(pgrep -f "ssh.*-L ${LOCAL_PORT}:${RDS_ENDPOINT}:${RDS_PORT}" | head -n1 || true)
  [[ -n "${TUNNEL_PID}" ]] || die "Failed to establish SSH tunnel."
  success "Tunnel up (pid ${TUNNEL_PID}): 127.0.0.1:${LOCAL_PORT} → ${RDS_ENDPOINT}:${RDS_PORT}"
fi

# ── Verify connectivity ───────────────────────────────────────────────────────
info "Verifying PostgreSQL connectivity …"
PGPASSWORD="${RDS_PASSWORD}" pg_isready -h "${PG_HOST}" -p "${PG_PORT}" -U "${RDS_USER}" > /dev/null \
  || die "Cannot reach PostgreSQL at ${PG_HOST}:${PG_PORT}."
success "PostgreSQL is reachable."

# ── Local dump directory ──────────────────────────────────────────────────────
mkdir -p "${LOCAL_DUMP_SUBDIR}"
success "Local dump directory ready: ${LOCAL_DUMP_SUBDIR}"

# ── Resolve database list ─────────────────────────────────────────────────────
if [[ "${EXPORT_SCOPE}" == "all" ]]; then
  info "Listing user databases …"
  DB_LIST=()
  while IFS= read -r db; do
    [[ -n "$db" ]] && DB_LIST+=("$db")
  done < <(PGPASSWORD="${RDS_PASSWORD}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${RDS_USER}" \
    -d postgres -tAc \
    "SELECT datname FROM pg_database
     WHERE datistemplate = false
       AND datname NOT IN ('postgres','rdsadmin')
     ORDER BY datname;")

  [[ ${#DB_LIST[@]} -gt 0 ]] || die "No user databases found on the source server."
  info "Databases to export: ${DB_LIST[*]}"
else
  DB_LIST=("${DB_NAME}")
fi

# ── Export each database ──────────────────────────────────────────────────────
info "This may take several minutes per database …"
for db in "${DB_LIST[@]}"; do
  LOCAL_DUMP_PATH="${LOCAL_DUMP_SUBDIR}/${db}.sql.gz"
  info "Exporting '${db}' → ${LOCAL_DUMP_PATH}"
  PGPASSWORD="${RDS_PASSWORD}" pg_dump \
    -h "${PG_HOST}" -p "${PG_PORT}" -U "${RDS_USER}" \
    -d "${db}" \
    --no-owner --no-acl --format=plain \
    | gzip > "${LOCAL_DUMP_PATH}"
  success "Exported: ${db}  ($(du -sh "${LOCAL_DUMP_PATH}" | cut -f1))"
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
echo "Next step — import into the Docker PostgreSQL on your EC2 instance:"
echo "  ./scripts/migration/aws/instance-import.sh"
echo "  (choose 'all' scope and point it at: ${LOCAL_DUMP_SUBDIR})"
