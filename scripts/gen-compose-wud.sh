#!/usr/bin/env bash
#
# gen-compose-wud.sh — Generate a WUD (What's Up Docker) compose file
#
# Usage (run from repo root):
#   ./scripts/gen-compose-wud.sh
#
# Generates under docker-images/<group>/<env>/app_services/:
#   compose.wud.yml   — WUD service (attaches to existing app-services network)
#
# WUD monitors running containers and notifies when new image versions are
# available on GitHub Container Registry (ghcr.io).
#
# The generated compose file is designed to sit alongside compose.app-services.yml
# on the App VM and share its Docker network.
#
# Previous values are saved to ~/.config/docker-compose-gen/wud.conf
#
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_IMAGES_DIR="${REPO_ROOT}/docker-images"

CONF_DIR="${HOME}/.config/docker-compose-gen"
CONF_FILE="${CONF_DIR}/wud.conf"

# ── Previous values ───────────────────────────────────────────────────────────
PREV_GROUP=""
PREV_ENV=""
PREV_GHCR_ORG=""
PREV_WUD_PORT=""
PREV_WUD_CRON=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# docker-compose-gen/wud — last used values (auto-generated, do not commit)
PREV_GROUP="${GROUP}"
PREV_ENV="${ENV}"
PREV_GHCR_ORG="${GHCR_ORG}"
PREV_WUD_PORT="${WUD_PORT}"
PREV_WUD_CRON="${WUD_CRON}"
CONF
}

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Prompt helpers ────────────────────────────────────────────────────────────
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

# ── Generate compose.wud.yml ──────────────────────────────────────────────────
gen_wud_compose() {
  local file="$1"
  local group="$2"
  local env="$3"
  local ghcr_org="$4"
  local wud_port="$5"
  local wud_cron="$6"
  cat > "$file" << EOF
services:
  wud:
    image: ghcr.io/getwud/wud:8.2.2
    container_name: ${group}-${env}-wud
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - wud_store:/store
    ports:
      - "\${WUD_PORT:-${wud_port}}:3000"
    environment:
      # GitHub Container Registry — token needs read:packages scope
      WUD_REGISTRY_GHCR_TOKEN: \${WUD_REGISTRY_GHCR_TOKEN}
      WUD_REGISTRY_GHCR_ORGANIZATION: ${ghcr_org}

      # Polling schedule (cron expression)
      WUD_WATCHER_LOCAL_CRON: ${wud_cron}

      # Web UI
      WUD_SERVER_PORT: 3000

      # Log level: error | warn | info | debug
      WUD_LOG_LEVEL: \${WUD_LOG_LEVEL:-info}
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  wud_store:
EOF
}

# ── Generate .env.wud.example ─────────────────────────────────────────────────
gen_wud_env_example() {
  local file="$1"
  local wud_port="$2"

  cat > "$file" << EOF
# WUD environment variables — copy to .env.wud and fill in real values
# Never commit .env.wud to version control

# GitHub PAT with read:packages scope
WUD_REGISTRY_GHCR_TOKEN=ghp_your_token_here

# Web UI host port (default: ${wud_port})
WUD_PORT=${wud_port}

# Log level: error | warn | info | debug
WUD_LOG_LEVEL=info
EOF
}

# ── Load config ───────────────────────────────────────────────────────────────
load_config

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  WUD Compose Generator                     ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Prompts ───────────────────────────────────────────────────────────────────
echo -e "${YELLOW}── Target ────────────────────────────────────────────────${NC}"
prompt GROUP "Group name"                              "${PREV_GROUP}"
prompt ENV   "Environment (e.g. qa, prod, staging)"   "${PREV_ENV}"

APP_DIR="${DOCKER_IMAGES_DIR}/${GROUP}/${ENV}/app_services"
OUT_COMPOSE="${APP_DIR}/compose.wud.yml"
OUT_ENV_EXAMPLE="${APP_DIR}/.env.wud.example"

if [[ -f "${OUT_COMPOSE}" ]]; then
  echo
  die "Output file already exists — refusing to overwrite:
    ${OUT_COMPOSE}

  Delete or move it manually, then re-run the script."
fi

echo
echo -e "${YELLOW}── GitHub Container Registry ─────────────────────────────${NC}"
echo -e "  WUD will watch images from ghcr.io/<org>/*"
prompt GHCR_ORG "GHCR organisation or user (e.g. myorg)" "${PREV_GHCR_ORG}"

echo
echo -e "${YELLOW}── WUD settings ──────────────────────────────────────────${NC}"
prompt WUD_PORT "Host port for WUD web UI"            "${PREV_WUD_PORT:-9080}"
prompt WUD_CRON "Poll schedule (cron, UTC)"           "${PREV_WUD_CRON:-0 * * * *}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}── Summary ───────────────────────────────────────────────${NC}"
echo "  Group         : ${GROUP}"
echo "  Environment   : ${ENV}"
echo "  GHCR org      : ${GHCR_ORG}"
echo "  Web UI port   : ${WUD_PORT}"
echo "  Poll schedule : ${WUD_CRON}"
echo
echo "  Files to write:"
echo "    ${OUT_COMPOSE}"
echo "    ${OUT_ENV_EXAMPLE}"
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Generate files ────────────────────────────────────────────────────────────
mkdir -p "${APP_DIR}"

echo
info "Generating compose.wud.yml …"
gen_wud_compose "${OUT_COMPOSE}" "${GROUP}" "${ENV}" "${GHCR_ORG}" "${WUD_PORT}" "${WUD_CRON}"
success "Written: ${OUT_COMPOSE}"

info "Generating .env.wud.example …"
gen_wud_env_example "${OUT_ENV_EXAMPLE}" "${WUD_PORT}"
success "Written: ${OUT_ENV_EXAMPLE}"

# ── Save config ───────────────────────────────────────────────────────────────
save_config
success "Saved values to ${CONF_FILE}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Done!                                     ${NC}"
echo -e "${GREEN}============================================${NC}"
echo
echo "Generated files under docker-images/${GROUP}/${ENV}/app_services/"
echo
echo -e "${YELLOW}On the App VM:${NC}"
echo "  1. Copy compose.wud.yml and .env.wud.example to the app_services/ directory"
echo "  2. cp .env.wud.example .env.wud  &&  fill in WUD_REGISTRY_GHCR_TOKEN"
echo "  3. docker compose --env-file .env.wud -f compose.wud.yml up -d"
echo
echo -e "${YELLOW}WUD web UI:${NC}  http://<vm-ip>:${WUD_PORT}"
echo
