#!/usr/bin/env bash
#
# ansible-iap-run.sh — Run an Ansible playbook against a GCP VM via IAP tunnel
#
# GCP target values (project, zone, VM name) are read from tofu layer outputs.
# The VM is accessed through IAP; no external IP is required.
#
# Usage (run from repo root):
#   ./scripts/ansible-iap-run.sh
#
# Previous values are saved to ~/.config/ansible-iap/last.conf
#
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLAYBOOKS_DIR="${REPO_ROOT}/playbooks"
LAYERS_DIR="${REPO_ROOT}/layers"
TOFU_LAYER_RUN="${SCRIPT_DIR}/tofu-layer-run.sh"

CONF_DIR="${HOME}/.config/ansible-iap"
CONF_FILE="${CONF_DIR}/last.conf"

# ── Saved values ──────────────────────────────────────────────────────────────
PREV_LAYER=""
PREV_AWS_PROFILE=""
PREV_WORKSPACE=""
PREV_GOOGLE_CREDENTIALS=""
PREV_VM_NAME=""
PREV_VM_USER=""
PREV_PLAYBOOK=""
PREV_ZEROTIER_NETWORK_ID=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# ansible-iap — last used values (auto-generated, do not commit)
PREV_LAYER="${LAYER}"
PREV_AWS_PROFILE="${AWS_PROFILE}"
PREV_WORKSPACE="${WORKSPACE}"
PREV_GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS}"
PREV_VM_NAME="${VM_NAME}"
PREV_VM_USER="${VM_USER}"
PREV_PLAYBOOK="${PLAYBOOK}"
PREV_ZEROTIER_NETWORK_ID="${ZEROTIER_NETWORK_ID:-}"
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
command -v jq             >/dev/null 2>&1 || die "'jq' is required but not installed."
command -v ansible-playbook >/dev/null 2>&1 || die "'ansible-playbook' is required but not installed."
command -v gcloud         >/dev/null 2>&1 || die "'gcloud' is required but not installed."
[[ -x "${TOFU_LAYER_RUN}" ]] || die "tofu-layer-run.sh not found or not executable: ${TOFU_LAYER_RUN}"

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
load_config

echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Ansible IAP Run — playbook via IAP tunnel ${NC}"
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

LAYER_JSON=$(echo "${RAW_OUTPUT}" | awk '/^\{/{found=1} found{print}')
[[ -n "${LAYER_JSON}" ]] || die "Could not parse JSON from tofu outputs. Run with 2>&1 to debug."

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

# ── Playbook selection ────────────────────────────────────────────────────────
echo -e "${YELLOW}── Playbook ──────────────────────────────────────────────${NC}"

PLAYBOOK_FILES=()
while IFS= read -r f; do
  PLAYBOOK_FILES+=("$(basename "$f")")
done < <(find "${PLAYBOOKS_DIR}" -maxdepth 1 -name "*.yml" | sort)
[[ ${#PLAYBOOK_FILES[@]} -gt 0 ]] || die "No .yml playbooks found under ${PLAYBOOKS_DIR}"

prompt_choice PLAYBOOK "Playbook to run" "${PREV_PLAYBOOK:-${PLAYBOOK_FILES[0]}}" "${PLAYBOOK_FILES[@]}"

EXTRA_VARS=""
read -r -p "$(echo -e "${CYAN}?${NC} Extra vars (e.g. key=val key2=val2, leave blank for none): ")" EXTRA_VARS
echo

# ── ZeroTier ──────────────────────────────────────────────────────────────────
CONFIGURE_ZEROTIER=false
ZEROTIER_NETWORK_ID="${PREV_ZEROTIER_NETWORK_ID:-}"

if [[ "${PLAYBOOK}" == "deployment.yml" || "${PLAYBOOK}" == "db.yml" || "${PLAYBOOK}" == "zerotier.yml" ]]; then
  echo -e "${YELLOW}── ZeroTier ───────────────────────────────────────────────${NC}"

  if [[ "${PLAYBOOK}" == "zerotier.yml" ]]; then
    CONFIGURE_ZEROTIER=true
  else
    read -r -p "$(echo -e "${CYAN}?${NC} Configure ZeroTier? [y/N]: ")" ZT_CONFIRM
    [[ "$(echo "${ZT_CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] && CONFIGURE_ZEROTIER=true
  fi

  if [[ "${CONFIGURE_ZEROTIER}" == "true" ]]; then
    prompt ZEROTIER_NETWORK_ID "ZeroTier network ID (16-hex)" "${PREV_ZEROTIER_NETWORK_ID}"
  fi
  echo
fi

# ── Summary ───────────────────────────────────────────────────────────────────
PROXY_CMD="gcloud compute start-iap-tunnel ${VM_NAME} 22 --listen-on-stdin --zone=${GCP_ZONE} --project=${GCP_PROJECT}"

echo -e "${YELLOW}── Summary ───────────────────────────────────────────────${NC}"
echo "  Playbook    : ${PLAYBOOK}"
echo "  VM          : ${VM_NAME} (zone: ${GCP_ZONE})"
echo "  GCP project : ${GCP_PROJECT}"
echo "  User        : ${VM_USER}"
echo "  Extra vars  : ${EXTRA_VARS:-<none>}"
echo "  IAP tunnel  : yes"
if [[ "${CONFIGURE_ZEROTIER}" == "true" ]]; then
  echo "  ZeroTier    : yes"
  echo "    network   : ${ZEROTIER_NETWORK_ID}"
fi
echo
echo -e "  Command that will run:"
echo -e "  ${CYAN}ansible-playbook -i \"local,\" ${PLAYBOOK} \\${NC}"
echo -e "  ${CYAN}    -u ${VM_USER} \\${NC}"
echo -e "  ${CYAN}    -e \"ansible_host=${VM_NAME}\" \\${NC}"
[[ -n "${EXTRA_VARS}" ]] && echo -e "  ${CYAN}    -e \"${EXTRA_VARS}\" \\${NC}"
echo -e "  ${CYAN}    --ssh-extra-args='-o ProxyCommand=\"${PROXY_CMD}\"'${NC}"
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Aborted."; exit 0; }

# ── Run ansible-playbook ──────────────────────────────────────────────────────
echo
cd "${PLAYBOOKS_DIR}"

ANSIBLE_EXTRA_VARS_ARGS=(-e "ansible_host=${VM_NAME}")
[[ -n "${EXTRA_VARS}" ]] && ANSIBLE_EXTRA_VARS_ARGS+=(-e "${EXTRA_VARS}")
if [[ "${CONFIGURE_ZEROTIER}" == "true" ]]; then
  ANSIBLE_EXTRA_VARS_ARGS+=(-e "zerotier_network_id=${ZEROTIER_NETWORK_ID}")
fi

if [[ "${CONFIGURE_ZEROTIER}" == "true" && "${PLAYBOOK}" != "zerotier.yml" ]]; then
  info "Configuring ZeroTier on ${VM_NAME} …"
  echo
  ansible-playbook \
    -i "local," \
    "zerotier.yml" \
    -u "${VM_USER}" \
    -e "ansible_host=${VM_NAME}" \
    -e "zerotier_network_id=${ZEROTIER_NETWORK_ID}" \
    --ssh-extra-args="-o ProxyCommand=\"${PROXY_CMD}\""
  echo
fi

info "Running playbook '${PLAYBOOK}' against ${VM_NAME} via IAP …"
echo

ansible-playbook \
  -i "local," \
  "${PLAYBOOK}" \
  -u "${VM_USER}" \
  "${ANSIBLE_EXTRA_VARS_ARGS[@]}" \
  --ssh-extra-args="-o ProxyCommand=\"${PROXY_CMD}\""

# ── Save config ───────────────────────────────────────────────────────────────
save_config
success "Saved values to ${CONF_FILE}"

echo
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Done!                                     ${NC}"
echo -e "${GREEN}============================================${NC}"
echo
