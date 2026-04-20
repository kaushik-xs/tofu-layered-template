#!/usr/bin/env bash
#
# gcp-scp-env-configs.sh — SCP a docker-images service directory to a GCP Compute Engine VM via IAP
#
# GCP target values (project, zone, VM name) are read directly from tofu layer outputs.
#
# Usage (run from repo root):
#   ./scripts/gcp-scp-env-configs.sh
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
LAYERS_DIR="${REPO_ROOT}/layers"
TOFU_LAYER_RUN="${SCRIPT_DIR}/tofu-layer-run.sh"

CONF_DIR="${HOME}/.config/gcp-scp"
CONF_FILE="${CONF_DIR}/last.conf"

# ── Saved values ──────────────────────────────────────────────────────────────
PREV_LAYER=""
PREV_AWS_PROFILE=""
PREV_WORKSPACE=""
PREV_GOOGLE_CREDENTIALS=""
PREV_GROUP=""
PREV_ENV=""
PREV_SERVICE_DIR=""
PREV_VM_USER=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# gcp-scp — last used values (auto-generated, do not commit)
PREV_LAYER="${LAYER}"
PREV_AWS_PROFILE="${AWS_PROFILE}"
PREV_WORKSPACE="${WORKSPACE}"
PREV_GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS}"
PREV_GROUP="${GROUP}"
PREV_ENV="${ENV}"
PREV_SERVICE_DIR="${SERVICE_DIR}"
PREV_VM_USER="${VM_USER}"
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

# Numbered menu; stores chosen item (not index) in var_name.
prompt_choice() {
  local var_name="$1" prompt_text="$2" default_item="$3"
  shift 3
  local options=("$@") i value="" default_idx=1
  for i in "${!options[@]}"; do
    [[ "${options[$i]}" == "${default_item}" ]] && default_idx=$((i + 1))
  done
  echo -e "  ${CYAN}?${NC} ${prompt_text}:"
  for i in "${!options[@]}"; do
    echo "      $((i+1))) ${options[$i]}"
  done
  read -r -p "    Choice [${default_idx}]: " value
  [[ -z "$value" ]] && value="${default_idx}"
  [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le "${#options[@]}" ]] \
    || die "Invalid choice '${value}'. Enter a number between 1 and ${#options[@]}."
  printf -v "$var_name" '%s' "${options[$(( value - 1 ))]}"
}

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq  >/dev/null 2>&1 || die "'jq' is required but not installed."
[[ -x "${TOFU_LAYER_RUN}" ]] || die "tofu-layer-run.sh not found or not executable: ${TOFU_LAYER_RUN}"

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

# ── Layer selection ───────────────────────────────────────────────────────────
echo -e "${YELLOW}── OpenTofu Layer ────────────────────────────────────────${NC}"

AVAILABLE_LAYERS=()
for d in "${LAYERS_DIR}"/*/; do
  [[ -d "$d" ]] && AVAILABLE_LAYERS+=("$(basename "$d")")
done
[[ ${#AVAILABLE_LAYERS[@]} -gt 0 ]] || die "No layer directories found under ${LAYERS_DIR}"

prompt_choice LAYER "Layer to fetch GCP outputs from" "${PREV_LAYER:-project}" "${AVAILABLE_LAYERS[@]}"

prompt AWS_PROFILE "AWS profile"  "${PREV_AWS_PROFILE}"
prompt WORKSPACE   "Workspace"    "${PREV_WORKSPACE}"

# GOOGLE_CREDENTIALS: env takes precedence, then saved, then prompt
if [[ -z "${GOOGLE_CREDENTIALS:-}" ]]; then
  if [[ -n "${PREV_GOOGLE_CREDENTIALS}" ]]; then
    GOOGLE_CREDENTIALS="${PREV_GOOGLE_CREDENTIALS}"
    info "Using saved GOOGLE_CREDENTIALS: ${GOOGLE_CREDENTIALS}"
  else
    prompt GOOGLE_CREDENTIALS "Path to GCP service account JSON key" ""
  fi
fi
echo

# ── Fetch layer outputs ───────────────────────────────────────────────────────
info "Fetching outputs from layer '${LAYER}' (workspace: ${WORKSPACE}, profile: ${AWS_PROFILE}) …"
echo

RAW_OUTPUT=$(
  AWS_PROFILE="${AWS_PROFILE}" \
  GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS}" \
  "${TOFU_LAYER_RUN}" "${LAYER}" "${WORKSPACE}" output 2>/dev/null
) || die "Failed to fetch tofu outputs for layer '${LAYER}'."

# Extract the JSON object — tofu output -json starts with '{' on its own line
LAYER_JSON=$(echo "${RAW_OUTPUT}" | awk '/^\{/{found=1} found{print}')
[[ -n "${LAYER_JSON}" ]] || die "Could not parse JSON from tofu outputs. Run with 2>&1 to debug."

# Validate required keys
GCP_PROJECT=$(echo "${LAYER_JSON}" | jq -r '.gcp_project_id.value // empty') \
  || die "Failed to parse layer JSON."
[[ -n "${GCP_PROJECT}" ]] || die "Output 'gcp_project_id' not found in layer '${LAYER}'. Choose a layer that exposes GCP compute outputs."

GCP_INSTANCES_JSON=$(echo "${LAYER_JSON}" | jq '.gcp_instances.value // empty')
[[ -n "${GCP_INSTANCES_JSON}" && "${GCP_INSTANCES_JSON}" != "null" ]] \
  || die "Output 'gcp_instances' not found in layer '${LAYER}'."

VM_COUNT=$(echo "${GCP_INSTANCES_JSON}" | jq 'length')
[[ "${VM_COUNT}" -gt 0 ]] || die "No GCP instances found in layer '${LAYER}' outputs."

# ── VM selection ──────────────────────────────────────────────────────────────
echo -e "${YELLOW}── GCP Target (from layer outputs) ───────────────────────${NC}"
info "GCP project : ${GCP_PROJECT}"

if [[ "${VM_COUNT}" -eq 1 ]]; then
  VM_NAME=$(echo "${GCP_INSTANCES_JSON}" | jq -r '.[0].name')
  GCP_ZONE=$(echo "${GCP_INSTANCES_JSON}" | jq -r '.[0].zone')
  info "Auto-selected VM : ${VM_NAME} (zone: ${GCP_ZONE})"
else
  VM_NAMES=()
  while IFS= read -r name; do
    VM_NAMES+=("$name")
  done < <(echo "${GCP_INSTANCES_JSON}" | jq -r '.[].name')

  prompt_choice VM_NAME "Target VM" "${PREV_VM_NAME:-${VM_NAMES[0]}}" "${VM_NAMES[@]}"
  GCP_ZONE=$(echo "${GCP_INSTANCES_JSON}" | jq -r --arg n "${VM_NAME}" '.[] | select(.name == $n) | .zone')
  info "Zone : ${GCP_ZONE}"
fi

prompt VM_USER "Remote user" "${PREV_VM_USER:-ubuntu}"
echo

# ── Source group / env ────────────────────────────────────────────────────────
echo -e "${YELLOW}── Source ────────────────────────────────────────────────${NC}"
prompt GROUP "Group name (e.g. rg2k)"              "${PREV_GROUP}"
prompt ENV   "Environment (e.g. qa, prod, staging)" "${PREV_ENV}"
echo

# Resolve available service dirs
GROUP_ENV_DIR="${DOCKER_IMAGES_DIR}/${GROUP}/${ENV}"
[[ -d "${GROUP_ENV_DIR}" ]] \
  || die "Directory not found: ${GROUP_ENV_DIR}\n  Run gen-compose.sh first to generate service files."

SERVICE_DIRS=()
for d in "${GROUP_ENV_DIR}"/*/; do
  [[ -d "$d" ]] && SERVICE_DIRS+=("$(basename "$d")")
done
[[ ${#SERVICE_DIRS[@]} -gt 0 ]] || die "No sub-directories found under ${GROUP_ENV_DIR}"

prompt_choice SERVICE_DIR "Service directory to upload" "${PREV_SERVICE_DIR:-${SERVICE_DIRS[0]}}" "${SERVICE_DIRS[@]}"

SOURCE_PATH="${GROUP_ENV_DIR}/${SERVICE_DIR}"
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
