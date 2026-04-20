#!/usr/bin/env bash
#
# gen-compose.sh — Generate Docker Compose files for a group / environment
#
# Usage (run from repo root):
#   ./scripts/gen-compose.sh
#
# Generates files under docker-images/<group>/<env>/:
#   app_services/Makefile                  — App VM operations
#   app_services/compose.networks.yml      — single bridge network
#   app_services/compose.app-services.yml  — all app services
#   db_services/Makefile                   — DB VM operations (optional)
#   db_services/compose.networks.yml       — host-driver network (optional)
#   db_services/compose.db-services.yml    — all db services (optional)
#
# App services and DB services are designed to run on separate VMs.
# Each Makefile is self-contained for its VM — run it from that directory.
#
# Service spec format:  type:count[,type:count...]
#   App example:  next:2,node:2,python:3,rust:3
#   DB  example:  postgres:1,redis:1,mongo:1
#
# Previous values are saved to ~/.config/docker-compose-gen/last.conf
#
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_IMAGES_DIR="${REPO_ROOT}/docker-images"

CONF_DIR="${HOME}/.config/docker-compose-gen"
CONF_FILE="${CONF_DIR}/last.conf"

# ── Previous values ───────────────────────────────────────────────────────────
PREV_GROUP=""
PREV_ENV=""
PREV_GH_ORG=""
PREV_APP_SERVICES=""
PREV_GENERATE_DB=""
PREV_DB_SERVICES=""


load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# docker-compose-gen — last used values (auto-generated, do not commit)
PREV_GROUP="${GROUP}"
PREV_ENV="${ENV}"
PREV_GH_ORG="${GH_ORG}"
PREV_APP_SERVICES="${APP_SERVICES}"
PREV_GENERATE_DB="${GENERATE_DB}"
PREV_DB_SERVICES="${DB_SERVICES:-}"
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
  local value=""

  [[ -n "$default" ]] && prompt_text="${prompt_text} [${default}]"
  read -r -p "$(echo -e "${CYAN}?${NC} ${prompt_text}: ")" value
  [[ -z "$value" && -n "$default" ]] && value="$default"
  [[ -z "$value" ]] && die "Value for '${var_name}' is required."
  printf -v "$var_name" '%s' "$value"
}

# ── Y/N prompt helper ─────────────────────────────────────────────────────────
prompt_yn() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local display="y/n"
  local value=""

  if [[ "$default" == "y" ]]; then display="Y/n";
  elif [[ "$default" == "n" ]]; then display="y/N"; fi

  read -r -p "$(echo -e "${CYAN}?${NC} ${prompt_text} [${display}]: ")" value
  value="$(echo "${value:-$default}" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "y" || "$value" == "n" ]] || die "Please answer y or n."
  printf -v "$var_name" '%s' "$value"
}

# ── Service-type helpers ──────────────────────────────────────────────────────
get_app_base_port() {
  case "$1" in
    next)    echo 3000 ;;
    node)    echo 4000 ;;
    python)  echo 5000 ;;
    rust)    echo 8000 ;;
    go)      echo 8080 ;;
    *)       echo 9000 ;;
  esac
}

get_single_svc_name() {
  case "$1" in
    next)    echo "next-ui" ;;
    node)    echo "node-api" ;;
    python)  echo "python-api" ;;
    rust)    echo "rust-api" ;;
    go)      echo "go-api" ;;
    *)       echo "${1}-svc" ;;
  esac
}

get_db_image() {
  case "$1" in
    postgres)  echo "postgres:17-alpine" ;;
    redis)     echo "redis:7-alpine" ;;
    mongo)     echo "mongo:8.0" ;;
    mysql)     echo "mysql:8.4" ;;
    mariadb)   echo "mariadb:11.4" ;;
    *)         echo "${1}:latest" ;;
  esac
}

get_db_base_port() {
  case "$1" in
    postgres)  echo 5432 ;;
    redis)     echo 6379 ;;
    mongo)     echo 27017 ;;
    mysql)     echo 3306 ;;
    mariadb)   echo 3307 ;;
    *)         echo 9999 ;;
  esac
}

to_env_prefix() {
  echo "$1" | tr '[:lower:]-' '[:upper:]_'
}

# ── Validate service spec ─────────────────────────────────────────────────────
validate_spec() {
  local spec="$1"
  local label="$2"
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | tr -d ' ')"
    [[ "$part" =~ ^[a-zA-Z][a-zA-Z0-9_-]*:[0-9]+$ ]] \
      || die "Invalid ${label} spec '${part}'. Expected format: type:count (e.g. next:2)"
    local count
    count="$(echo "$part" | cut -d: -f2)"
    [[ "$count" -ge 1 ]] || die "Count must be >= 1 in '${part}'"
  done
}

# ── Print service breakdown ───────────────────────────────────────────────────
preview_services() {
  local label="$1"
  local spec="$2"
  echo -e "  ${YELLOW}${label}:${NC}"
  IFS=',' read -ra SPECS <<< "$spec"
  for s in "${SPECS[@]}"; do
    s="$(echo "$s" | tr -d ' ')"
    local type count
    type="$(echo "$s" | cut -d: -f1)"
    count="$(echo "$s" | cut -d: -f2)"
    echo "    • ${type} × ${count}"
  done
}

# ── Generate app networks file ────────────────────────────────────────────────
gen_app_networks() {
  local file="$1"
  local network_name="$2"
  cat > "$file" << YAML
networks:
  ${network_name}:
    driver: bridge
YAML
}

# ── Generate db networks file ─────────────────────────────────────────────────
gen_db_networks() {
  local file="$1"
  local network_name="$2"
  cat > "$file" << YAML
networks:
  ${network_name}:
    driver: host
YAML
}

# ── Generate app services compose ─────────────────────────────────────────────
gen_app_services() {
  local file="$1"
  local group="$2"
  local env="$3"
  local services_spec="$4"
  local gh_org="$5"
  local network_name="${group}-${env}-app-net"

  printf 'services:\n' > "$file"

  IFS=',' read -ra SPECS <<< "$services_spec"
  for spec in "${SPECS[@]}"; do
    spec="$(echo "$spec" | tr -d ' ')"
    local type count
    type="$(echo "$spec" | cut -d: -f1)"
    count="$(echo "$spec" | cut -d: -f2)"
    local base_port
    base_port="$(get_app_base_port "$type")"

    for i in $(seq 1 "$count"); do
      local svc_name port
      if [[ "$count" -eq 1 ]]; then
        port="$base_port"
      else
        port=$(( base_port + i - 1 ))
      fi
      local _ckey="APP_CUSTOM_NAME_${type//-/_}_${i}"
      if [[ -n "${!_ckey}" ]]; then
        svc_name="${!_ckey}"
      elif [[ "$count" -eq 1 ]]; then
        svc_name="$(get_single_svc_name "$type")"
      else
        svc_name="${type}-${i}"
      fi
      local env_prefix
      env_prefix="$(to_env_prefix "$svc_name")"

      printf '  %s:\n'                                                          "$svc_name"     >> "$file"
      printf '    image: ghcr.io/%s/%s:${%s_IMAGE_TAG:-latest}\n'              "$gh_org" "$svc_name" "$env_prefix" >> "$file"
      printf '    container_name: %s-%s-%s\n'                                   "$group" "$env" "$svc_name" >> "$file"
      printf '    restart: unless-stopped\n'                                                    >> "$file"
      printf '    ports:\n'                                                                     >> "$file"
      printf '      - "${%s_PORT:-%s}:%s"\n'                                    "$env_prefix" "$port" "$port" >> "$file"
      printf '    environment:\n'                                                               >> "$file"
      printf '      NODE_ENV: ${NODE_ENV:-production}\n'                                       >> "$file"
      printf '    env_file:\n'                                                                  >> "$file"
      printf '      - ./%s/.env\n'                                              "$svc_name"     >> "$file"
      printf '    networks:\n'                                                                  >> "$file"
      printf '      - %s\n'                                                     "$network_name" >> "$file"
      printf '    healthcheck:\n'                                                               >> "$file"
      printf '      test: ["CMD-SHELL", "wget -qO- http://localhost:%s/health || exit 1"]\n' "$port" >> "$file"
      printf '      interval: 15s\n'                                                           >> "$file"
      printf '      timeout: 5s\n'                                                             >> "$file"
      printf '      retries: 3\n'                                                              >> "$file"
      printf '\n'                                                                               >> "$file"
    done
  done

  printf 'networks:\n'              >> "$file"
  printf '  %s:\n' "$network_name" >> "$file"
  printf '    external: true\n'    >> "$file"
}

# ── Generate db services compose ──────────────────────────────────────────────
gen_db_services() {
  local file="$1"
  local group="$2"
  local env="$3"
  local services_spec="$4"

  local vol_names=()

  printf 'services:\n' > "$file"

  IFS=',' read -ra SPECS <<< "$services_spec"
  for spec in "${SPECS[@]}"; do
    spec="$(echo "$spec" | tr -d ' ')"
    local type count
    type="$(echo "$spec" | cut -d: -f1)"
    count="$(echo "$spec" | cut -d: -f2)"
    local image base_port
    image="$(get_db_image "$type")"
    base_port="$(get_db_base_port "$type")"

    for i in $(seq 1 "$count"); do
      local svc_name port
      if [[ "$count" -eq 1 ]]; then
        port="$base_port"
      else
        port=$(( base_port + i - 1 ))
      fi
      local _ckey="DB_CUSTOM_NAME_${type//-/_}_${i}"
      if [[ -n "${!_ckey}" ]]; then
        svc_name="${!_ckey}"
      elif [[ "$count" -eq 1 ]]; then
        svc_name="$type"
      else
        svc_name="${type}-${i}"
      fi

      local vol_name
      vol_name="${group}_${env}_$(echo "$svc_name" | tr '-' '_')_data"
      vol_names+=("$vol_name")

      local env_prefix
      env_prefix="$(to_env_prefix "$svc_name")"

      printf '  %s:\n'                    "$svc_name"              >> "$file"
      printf '    image: %s\n'            "$image"                 >> "$file"
      printf '    container_name: %s-%s-%s\n' "$group" "$env" "$svc_name" >> "$file"
      printf '    restart: unless-stopped\n'                       >> "$file"
      printf '    network_mode: host\n'                            >> "$file"

      case "$type" in
        postgres)
          printf '    environment:\n'                                                          >> "$file"
          printf '      POSTGRES_USER: ${%s_USER:-postgres}\n'     "$env_prefix"              >> "$file"
          printf '      POSTGRES_PASSWORD: ${%s_PASSWORD:-postgres}\n' "$env_prefix"          >> "$file"
          printf '      POSTGRES_DB: ${%s_DB:-%s}\n'               "$env_prefix" "$group"     >> "$file"
          if [[ "$count" -gt 1 ]]; then
            printf '      PGPORT: %s\n'                            "$port"                    >> "$file"
          fi
          printf '    volumes:\n'                                                              >> "$file"
          printf '      - %s:/var/lib/postgresql/data\n'           "$vol_name"                >> "$file"
          printf '    healthcheck:\n'                                                          >> "$file"
          printf '      test: ["CMD-SHELL", "pg_isready -U ${%s_USER:-postgres}"]\n' "$env_prefix" >> "$file"
          printf '      interval: 5s\n'                                                       >> "$file"
          printf '      timeout: 5s\n'                                                        >> "$file"
          printf '      retries: 5\n'                                                         >> "$file"
          ;;
        redis)
          printf '    volumes:\n'                                                              >> "$file"
          printf '      - %s:/data\n'                              "$vol_name"                >> "$file"
          printf '    healthcheck:\n'                                                          >> "$file"
          printf '      test: ["CMD", "redis-cli", "ping"]\n'                                 >> "$file"
          printf '      interval: 5s\n'                                                       >> "$file"
          printf '      timeout: 3s\n'                                                        >> "$file"
          printf '      retries: 5\n'                                                         >> "$file"
          ;;
        mongo)
          printf '    environment:\n'                                                          >> "$file"
          printf '      MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER:-mongo}\n'                   >> "$file"
          printf '      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD:-mongo}\n'               >> "$file"
          printf '    volumes:\n'                                                              >> "$file"
          printf '      - %s:/data/db\n'                           "$vol_name"                >> "$file"
          printf '    healthcheck:\n'                                                          >> "$file"
          printf "      test: [\"CMD\", \"mongosh\", \"--eval\", \"db.adminCommand('ping')\"]\n" >> "$file"
          printf '      interval: 10s\n'                                                      >> "$file"
          printf '      timeout: 5s\n'                                                        >> "$file"
          printf '      retries: 5\n'                                                         >> "$file"
          ;;
        mysql|mariadb)
          printf '    environment:\n'                                                          >> "$file"
          printf '      MYSQL_ROOT_PASSWORD: ${%s_ROOT_PASSWORD:-rootpassword}\n' "$env_prefix" >> "$file"
          printf '      MYSQL_DATABASE: ${%s_DB:-%s}\n'            "$env_prefix" "$group"     >> "$file"
          printf '      MYSQL_USER: ${%s_USER:-dbuser}\n'          "$env_prefix"              >> "$file"
          printf '      MYSQL_PASSWORD: ${%s_PASSWORD:-dbpassword}\n' "$env_prefix"           >> "$file"
          printf '    volumes:\n'                                                              >> "$file"
          printf '      - %s:/var/lib/mysql\n'                     "$vol_name"                >> "$file"
          printf '    healthcheck:\n'                                                          >> "$file"
          printf '      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]\n'             >> "$file"
          printf '      interval: 10s\n'                                                      >> "$file"
          printf '      timeout: 5s\n'                                                        >> "$file"
          printf '      retries: 5\n'                                                         >> "$file"
          ;;
        *)
          printf '    volumes:\n'                                                              >> "$file"
          printf '      - %s:/data\n'                              "$vol_name"                >> "$file"
          ;;
      esac

      printf '\n' >> "$file"
    done
  done

  if [[ ${#vol_names[@]} -gt 0 ]]; then
    printf 'volumes:\n' >> "$file"
    for vol in "${vol_names[@]}"; do
      printf '  %s:\n' "$vol" >> "$file"
    done
  fi
}

# ── Shared Makefile tail (list, restart-container, logs) ──────────────────────
_makefile_shared_targets() {
  local file="$1"
  local group="$2"
  local env="$3"

  printf '# List all containers for this group/env on this VM\n' >> "$file"
  printf 'list:\n' >> "$file"
  printf '\tdocker ps --filter "name=%s-%s" --format "table {{.Names}}\\t{{.Status}}\\t{{.Ports}}"\n' \
    "$group" "$env" >> "$file"
  printf '\n' >> "$file"

  printf '# Restart a specific container.  Usage: make restart-container c=<container-name>\n' >> "$file"
  printf 'restart-container:\n' >> "$file"
  printf '\t@[ "$$(c)" ] || { echo "Usage: make restart-container c=<container-name>"; exit 1; }\n' >> "$file"
  printf '\tdocker restart $$(c)\n' >> "$file"
  printf '\n' >> "$file"

  printf '# Tail logs of a specific container.  Usage: make logs c=<container-name>  (Ctrl-C to stop)\n' >> "$file"
  printf 'logs:\n' >> "$file"
  printf '\t@[ "$$(c)" ] || { echo "Usage: make logs c=<container-name>"; exit 1; }\n' >> "$file"
  printf '\tdocker logs -f $$(c)\n' >> "$file"
  printf '\n' >> "$file"
}

# ── Generate app_services/Makefile (App VM) ───────────────────────────────────
gen_app_makefile() {
  local file="$1"
  local group="$2"
  local env="$3"

  printf '# App VM — copy this directory to the app VM and run make from here\n' > "$file"
  printf '.PHONY: up down restart ps list restart-container logs\n\n' >> "$file"

  printf 'up:\n' >> "$file"
  printf '\tdocker compose -f compose.networks.yml up -d\n'     >> "$file"
  printf '\tdocker compose -f compose.app-services.yml up -d\n' >> "$file"
  printf '\n' >> "$file"

  printf 'down:\n' >> "$file"
  printf '\tdocker compose -f compose.app-services.yml down\n'  >> "$file"
  printf '\tdocker compose -f compose.networks.yml down\n'      >> "$file"
  printf '\n' >> "$file"

  printf 'restart: down up\n\n' >> "$file"

  printf 'ps:\n' >> "$file"
  printf '\tdocker compose -f compose.app-services.yml ps\n' >> "$file"
  printf '\n' >> "$file"

  _makefile_shared_targets "$file" "$group" "$env"
}

# ── Generate db_services/Makefile (DB VM) ────────────────────────────────────
gen_db_makefile() {
  local file="$1"
  local group="$2"
  local env="$3"

  printf '# DB VM — copy this directory to the DB VM and run make from here\n' > "$file"
  printf '.PHONY: up down restart ps list restart-container logs\n\n' >> "$file"

  printf 'up:\n' >> "$file"
  printf '\tdocker compose -f compose.networks.yml up -d\n'    >> "$file"
  printf '\tdocker compose -f compose.db-services.yml up -d\n' >> "$file"
  printf '\n' >> "$file"

  printf 'down:\n' >> "$file"
  printf '\tdocker compose -f compose.db-services.yml down\n'  >> "$file"
  printf '\tdocker compose -f compose.networks.yml down\n'     >> "$file"
  printf '\n' >> "$file"

  printf 'restart: down up\n\n' >> "$file"

  printf 'ps:\n' >> "$file"
  printf '\tdocker compose -f compose.db-services.yml ps\n' >> "$file"
  printf '\n' >> "$file"

  _makefile_shared_targets "$file" "$group" "$env"
}

# ── Load config ───────────────────────────────────────────────────────────────
load_config

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Docker Compose Generator                  ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Prompts ───────────────────────────────────────────────────────────────────
echo -e "${YELLOW}── Target ────────────────────────────────────────────────${NC}"
prompt GROUP "Group name"           "${PREV_GROUP}"
prompt ENV    "Environment (e.g. qa, prod, staging)"   "${PREV_ENV}"
prompt GH_ORG "GitHub organisation (for ghcr.io image path)" "${PREV_GH_ORG:-${PREV_GROUP}}"

echo
echo -e "${YELLOW}── App services ──────────────────────────────────────────${NC}"
echo -e "  Format: ${CYAN}type:count${NC} comma-separated"
echo -e "  e.g. next:2,node:2,python:3,rust:3"
echo -e "  Known types: next · node · python · rust · go  (custom names also work)"
prompt APP_SERVICES "App services" "${PREV_APP_SERVICES:-next:1,node:1}"
validate_spec "$APP_SERVICES" "app services"

echo
prompt_yn _APP_CUSTOM "Customise app service names?" "n"
if [[ "$_APP_CUSTOM" == "y" ]]; then
  echo -e "  Press Enter to accept the default name for each instance."
  IFS=',' read -ra _ASPECS <<< "$APP_SERVICES"
  for _as in "${_ASPECS[@]}"; do
    _as="$(echo "$_as" | tr -d ' ')"
    _atype="$(echo "$_as" | cut -d: -f1)"
    _acount="$(echo "$_as" | cut -d: -f2)"
    for _ai in $(seq 1 "$_acount"); do
      if [[ "$_acount" -eq 1 ]]; then _adefault="$(get_single_svc_name "$_atype")"
      else _adefault="${_atype}-${_ai}"; fi
      prompt _aname "  ${_atype} #${_ai} service name" "$_adefault"
      printf -v "APP_CUSTOM_NAME_${_atype//-/_}_${_ai}" '%s' "$_aname"
    done
  done
fi

echo
echo -e "${YELLOW}── DB services ───────────────────────────────────────────${NC}"
warn "Skip this if your databases are already running on a separate VM or managed service."
prompt_yn GENERATE_DB "Generate DB service files?" "${PREV_GENERATE_DB:-y}"

DB_SERVICES=""
if [[ "$GENERATE_DB" == "y" ]]; then
  echo -e "  Format: ${CYAN}type:count${NC} comma-separated"
  echo -e "  e.g. postgres:1,redis:1,mongo:1"
  echo -e "  Known types: postgres · redis · mongo · mysql · mariadb"
  prompt DB_SERVICES "DB services" "${PREV_DB_SERVICES:-postgres:1}"
  validate_spec "$DB_SERVICES" "db services"

  echo
  prompt_yn _DB_CUSTOM "Customise DB service names?" "n"
  if [[ "$_DB_CUSTOM" == "y" ]]; then
    echo -e "  Press Enter to accept the default name for each instance."
    IFS=',' read -ra _DSPECS <<< "$DB_SERVICES"
    for _ds in "${_DSPECS[@]}"; do
      _ds="$(echo "$_ds" | tr -d ' ')"
      _dtype="$(echo "$_ds" | cut -d: -f1)"
      _dcount="$(echo "$_ds" | cut -d: -f2)"
      for _di in $(seq 1 "$_dcount"); do
        if [[ "$_dcount" -eq 1 ]]; then _ddefault="$_dtype"
        else _ddefault="${_dtype}-${_di}"; fi
        prompt _dname "  ${_dtype} #${_di} service name" "$_ddefault"
        printf -v "DB_CUSTOM_NAME_${_dtype//-/_}_${_di}" '%s' "$_dname"
      done
    done
  fi
else
  info "Skipping DB service file generation."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
APP_DIR="${DOCKER_IMAGES_DIR}/${GROUP}/${ENV}/app_services"
DB_DIR="${DOCKER_IMAGES_DIR}/${GROUP}/${ENV}/db_services"

echo
echo -e "${YELLOW}── Summary ───────────────────────────────────────────────${NC}"
echo "  Group       : ${GROUP}"
echo "  Environment : ${ENV}"
echo "  GitHub org  : ${GH_ORG}  (ghcr.io/${GH_ORG}/...)"
preview_services "App services" "$APP_SERVICES"
if [[ "$GENERATE_DB" == "y" ]]; then
  preview_services "DB services" "$DB_SERVICES"
else
  echo -e "  ${YELLOW}DB services:${NC} skipped (using existing DB)"
fi
echo
echo "  Files to write:"
echo "    ${APP_DIR}/Makefile"
echo "    ${APP_DIR}/compose.networks.yml"
echo "    ${APP_DIR}/compose.app-services.yml"
if [[ "$GENERATE_DB" == "y" ]]; then
  echo "    ${DB_DIR}/Makefile"
  echo "    ${DB_DIR}/compose.networks.yml"
  echo "    ${DB_DIR}/compose.db-services.yml"
fi
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Generate files ────────────────────────────────────────────────────────────
mkdir -p "${APP_DIR}"
[[ "$GENERATE_DB" == "y" ]] && mkdir -p "${DB_DIR}"

APP_NETWORK="${GROUP}-${ENV}-app-net"
DB_NETWORK="${GROUP}-${ENV}-db-net"

echo
info "Generating app_services/Makefile …"
gen_app_makefile "${APP_DIR}/Makefile" "${GROUP}" "${ENV}"
success "Written: ${APP_DIR}/Makefile"

info "Generating app_services/compose.networks.yml …"
gen_app_networks "${APP_DIR}/compose.networks.yml" "${APP_NETWORK}"
success "Written: ${APP_DIR}/compose.networks.yml"

info "Generating app_services/compose.app-services.yml …"
gen_app_services "${APP_DIR}/compose.app-services.yml" "${GROUP}" "${ENV}" "${APP_SERVICES}" "${GH_ORG}"
success "Written: ${APP_DIR}/compose.app-services.yml"

if [[ "$GENERATE_DB" == "y" ]]; then
  info "Generating db_services/Makefile …"
  gen_db_makefile "${DB_DIR}/Makefile" "${GROUP}" "${ENV}"
  success "Written: ${DB_DIR}/Makefile"

  info "Generating db_services/compose.networks.yml …"
  gen_db_networks "${DB_DIR}/compose.networks.yml" "${DB_NETWORK}"
  success "Written: ${DB_DIR}/compose.networks.yml"

  info "Generating db_services/compose.db-services.yml …"
  gen_db_services "${DB_DIR}/compose.db-services.yml" "${GROUP}" "${ENV}" "${DB_SERVICES}"
  success "Written: ${DB_DIR}/compose.db-services.yml"
fi

# ── Save config ───────────────────────────────────────────────────────────────
save_config
success "Saved values to ${CONF_FILE}"

# ── Done ──────────────────────────────────────────────────────────────────────
local_file_count=3
[[ "$GENERATE_DB" == "y" ]] && local_file_count=6

echo
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Done!                                     ${NC}"
echo -e "${GREEN}============================================${NC}"
echo
echo "Generated ${local_file_count} files under docker-images/${GROUP}/${ENV}/"
echo
echo -e "${YELLOW}App VM — deploy app_services/ and run:${NC}"
echo "  make up                          — start network + app containers"
echo "  make down                        — stop app containers + network"
echo "  make restart                     — down then up"
echo "  make ps                          — show running app containers"
echo "  make list                        — list all ${GROUP}-${ENV} containers"
echo "  make restart-container c=<name>  — restart one container"
echo "  make logs c=<name>               — tail logs of one container"
if [[ "$GENERATE_DB" == "y" ]]; then
  echo
  echo -e "${YELLOW}DB VM — deploy db_services/ and run:${NC}"
  echo "  make up                          — start network + db containers"
  echo "  make down                        — stop db containers + network"
  echo "  make restart                     — down then up"
  echo "  make ps                          — show running db containers"
  echo "  make list                        — list all ${GROUP}-${ENV} containers"
  echo "  make restart-container c=<name>  — restart one container"
  echo "  make logs c=<name>               — tail logs of one container"
fi
echo
