#!/usr/bin/env bash
#
# gcp-scp.sh — SCP a docker-images service directory to a GCP Compute Engine VM via IAP
#
# Usage (run from repo root):
#   ./scripts/gcp-scp.sh
#
# Uploads:  docker-images/<group>/<env>/<service_dir>/*
#       to: <user>@<vm_name>:/home/<user>
#
# Previous values are saved to ~/.config/gcp-scp/last.conf
#
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_IMAGES_DIR="${REPO_ROOT}/docker-images"

CONF_DIR="${HOME}/.config/gcp-scp"
CONF_FILE="${CONF_DIR}/last.conf"

# ── Saved values ──────────────────────────────────────────────────────────────
PREV_GROUP=""
PREV_ENV=""
PREV_SERVICE_DIR=""
PREV_VM_NAME=""
PREV_VM_USER=""
PREV_GCP_PROJECT=""
PREV_GCP_ZONE=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# gcp-scp — last used values (auto-generated, do not commit)
PREV_GROUP="${GROUP}"
PREV_ENV="${ENV}"
PREV_SERVICE_DIR="${SERVICE_DIR}"
PREV_VM_NAME="${VM_NAME}"
PREV_VM_USER="${VM_USER}"
PREV_GCP_PROJECT="${GCP_PROJECT}"
PREV_GCP_ZONE="${GCP_ZONE}"
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

# Numbered menu; stores chosen number (1-based) in var_name.
prompt_choice() {
  local var_name="$1" prompt_text="$2" default="$3"
  shift 3
  local options=("$@") i value=""
  echo -e "  ${CYAN}?${NC} ${prompt_text}:"
  for i in "${!options[@]}"; do
    echo "      $((i+1))) ${options[$i]}"
  done
  read -r -p "    Choice [${default}]: " value
  [[ -z "$value" ]] && value="$default"
  [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le "${#options[@]}" ]] \
    || die "Invalid choice '${value}'. Enter a number between 1 and ${#options[@]}."
  printf -v "$var_name" '%s' "$value"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
load_config

echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  GCP SCP — Upload service dir via IAP      ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Target group / env ────────────────────────────────────────────────────────
echo -e "${YELLOW}── Source ────────────────────────────────────────────────${NC}"
prompt GROUP "Group name (e.g. rg2k)"                    "${PREV_GROUP}"
prompt ENV   "Environment (e.g. qa, prod, staging)"      "${PREV_ENV}"
echo

# Resolve available service dirs
GROUP_ENV_DIR="${DOCKER_IMAGES_DIR}/${GROUP}/${ENV}"
[[ -d "${GROUP_ENV_DIR}" ]] \
  || die "Directory not found: ${GROUP_ENV_DIR}\n  Run gen-compose.sh first to generate service files."

# Collect service subdirs
SERVICE_DIRS=()
for d in "${GROUP_ENV_DIR}"/*/; do
  [[ -d "$d" ]] && SERVICE_DIRS+=("$(basename "$d")")
done

[[ ${#SERVICE_DIRS[@]} -gt 0 ]] \
  || die "No sub-directories found under ${GROUP_ENV_DIR}"

# Determine default choice index
_default_choice=1
for i in "${!SERVICE_DIRS[@]}"; do
  if [[ "${SERVICE_DIRS[$i]}" == "${PREV_SERVICE_DIR}" ]]; then
    _default_choice=$((i + 1))
    break
  fi
done

prompt_choice _svc_idx "Service directory to upload" "${_default_choice}" "${SERVICE_DIRS[@]}"
SERVICE_DIR="${SERVICE_DIRS[$((_svc_idx - 1))]}"

SOURCE_PATH="${GROUP_ENV_DIR}/${SERVICE_DIR}"
echo

# ── GCP target ────────────────────────────────────────────────────────────────
echo -e "${YELLOW}── GCP Target ────────────────────────────────────────────${NC}"
prompt GCP_PROJECT "GCP project ID"                         "${PREV_GCP_PROJECT}"
prompt GCP_ZONE    "Zone (e.g. asia-south1-a)"              "${PREV_GCP_ZONE}"
prompt VM_NAME     "VM name (e.g. qa-services)"             "${PREV_VM_NAME}"
prompt VM_USER     "Remote user"                            "${PREV_VM_USER:-ubuntu}"
echo

# ── Destination path ──────────────────────────────────────────────────────────
DEST_BASE="/home/${VM_USER}"
DEST_PATH="${VM_USER}@${VM_NAME}:${DEST_BASE}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${YELLOW}── Summary ───────────────────────────────────────────────${NC}"
echo "  Source      : ${SOURCE_PATH}/*"
echo "  Destination : ${DEST_PATH}"
echo "  GCP project : ${GCP_PROJECT}"
echo "  Zone        : ${GCP_ZONE}"
echo "  IAP tunnel  : yes"
echo
echo -e "  Command that will run:"
echo -e "  ${CYAN}gcloud compute scp \\${NC}"
echo -e "  ${CYAN}    --zone \"${GCP_ZONE}\" \\${NC}"
echo -e "  ${CYAN}    --tunnel-through-iap \\${NC}"
echo -e "  ${CYAN}    --project \"${GCP_PROJECT}\" \\${NC}"
echo -e "  ${CYAN}    --recurse \\${NC}"
echo -e "  ${CYAN}    \"${SOURCE_PATH}/\" \\${NC}"
echo -e "  ${CYAN}    \"${DEST_PATH}/${SERVICE_DIR}\"${NC}"
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Run SCP ───────────────────────────────────────────────────────────────────
echo
info "Uploading ${SERVICE_DIR}/ to ${VM_NAME}:${DEST_BASE}/${SERVICE_DIR} …"

gcloud compute scp \
  --zone "${GCP_ZONE}" \
  --tunnel-through-iap \
  --project "${GCP_PROJECT}" \
  --recurse \
  "${SOURCE_PATH}/" \
  "${DEST_PATH}/${SERVICE_DIR}"

# ── Save config ───────────────────────────────────────────────────────────────
save_config
success "Saved values to ${CONF_FILE}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Done!                                     ${NC}"
echo -e "${GREEN}============================================${NC}"
echo
echo -e "${YELLOW}Next steps — on ${VM_NAME}:${NC}"
echo "  cd ${DEST_BASE}/${SERVICE_DIR}"
echo "  make up"
echo
