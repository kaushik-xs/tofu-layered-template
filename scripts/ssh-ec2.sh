#!/usr/bin/env bash
#
# ssh-ec2.sh — SSH into an AWS EC2 instance
#
# Two modes:
#   1. Layer mode  — pick an instance from a tofu layer's `aws_instances` output
#                    (uses each instance's public/external IP).
#   2. Manual mode — type a host (IP or DNS) directly; works for any EC2,
#                    whether or not it was provisioned by this repo.
#
# Usage (run from repo root):
#   ./scripts/ssh-ec2.sh
#
# Previous values are saved to ~/.config/ssh-ec2/last.conf
#
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAYERS_DIR="${REPO_ROOT}/layers"
TOFU_LAYER_RUN="${SCRIPT_DIR}/tofu-layer-run.sh"

CONF_DIR="${HOME}/.config/ssh-ec2"
CONF_FILE="${CONF_DIR}/last.conf"

# ── Saved values ──────────────────────────────────────────────────────────────
PREV_MODE=""
PREV_LAYER=""
PREV_AWS_PROFILE=""
PREV_WORKSPACE=""
PREV_GOOGLE_CREDENTIALS=""
PREV_VM_NAME=""
PREV_SSH_USER=""
PREV_SSH_KEY=""
PREV_HOST=""
PREV_USE_JUMP=""
PREV_BASTION_VM=""
PREV_BASTION_HOST=""
PREV_BASTION_USER=""
PREV_BASTION_KEY=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# ssh-ec2 — last used values (auto-generated, do not commit)
PREV_MODE="${MODE}"
PREV_LAYER="${LAYER:-}"
PREV_AWS_PROFILE="${AWS_PROFILE:-}"
PREV_WORKSPACE="${WORKSPACE:-}"
PREV_GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS:-}"
PREV_VM_NAME="${VM_NAME:-}"
PREV_SSH_USER="${SSH_USER}"
PREV_SSH_KEY="${SSH_KEY}"
PREV_HOST="${HOST}"
PREV_USE_JUMP="${USE_JUMP:-no}"
PREV_BASTION_VM="${BASTION_VM:-}"
PREV_BASTION_HOST="${BASTION_HOST:-}"
PREV_BASTION_USER="${BASTION_USER:-}"
PREV_BASTION_KEY="${BASTION_KEY:-}"
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
  local var_name="$1" prompt_text="$2" default="${3:-}" value=""
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

# Expand leading ~, verify the key exists, and enforce safe perms (ssh refuses
# world-readable private keys). Writes the expanded path back to the named var.
ensure_key() {
  local key_var="$1" key="${!1}"
  key="${key/#\~/${HOME}}"
  [[ -f "$key" ]] || die "SSH key not found: ${key}"
  local perms
  perms=$(stat -c '%a' "$key" 2>/dev/null || stat -f '%Lp' "$key" 2>/dev/null || echo "")
  if [[ "$perms" != "400" && "$perms" != "600" ]]; then
    warn "Key ${key} has perms ${perms:-unknown}; tightening to 600."
    chmod 600 "$key"
  fi
  printf -v "$key_var" '%s' "$key"
}

# ── Dependency check ──────────────────────────────────────────────────────────
command -v ssh >/dev/null 2>&1 || die "'ssh' is required but not installed."

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
load_config

echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  SSH into EC2                               ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Mode selection ──────────────────────────────────────────────────────────
echo -e "${YELLOW}── Target source ─────────────────────────────────────────${NC}"
prompt_choice MODE "How to pick the host" "${PREV_MODE:-layer}" "layer" "manual"
echo

VM_NAME=""

if [[ "${MODE}" == "layer" ]]; then
  [[ -x "${TOFU_LAYER_RUN}" ]] || die "tofu-layer-run.sh not found or not executable: ${TOFU_LAYER_RUN}"
  command -v jq >/dev/null 2>&1 || die "'jq' is required for layer mode but not installed."

  echo -e "${YELLOW}── OpenTofu Layer ────────────────────────────────────────${NC}"
  AVAILABLE_LAYERS=()
  for d in "${LAYERS_DIR}"/*/; do
    [[ -d "$d" ]] && AVAILABLE_LAYERS+=("$(basename "$d")")
  done
  [[ ${#AVAILABLE_LAYERS[@]} -gt 0 ]] || die "No layer directories found under ${LAYERS_DIR}"

  prompt_choice LAYER "Layer to fetch AWS outputs from" "${PREV_LAYER:-project}" "${AVAILABLE_LAYERS[@]}"
  prompt AWS_PROFILE "AWS profile" "${PREV_AWS_PROFILE}"
  prompt WORKSPACE   "Workspace"   "${PREV_WORKSPACE}"

  # GCP creds may be needed for tofu init/providers; reuse saved or prompt (blank to skip).
  if [[ -z "${GOOGLE_CREDENTIALS:-}" ]]; then
    if [[ -n "${PREV_GOOGLE_CREDENTIALS}" ]]; then
      GOOGLE_CREDENTIALS="${PREV_GOOGLE_CREDENTIALS}"
      info "Using saved GOOGLE_CREDENTIALS: ${GOOGLE_CREDENTIALS}"
    else
      read -r -p "$(echo -e "${CYAN}?${NC} Path to GCP service account JSON key (blank to skip): ")" GOOGLE_CREDENTIALS
    fi
  fi
  echo

  info "Fetching outputs from layer '${LAYER}' (workspace: ${WORKSPACE}, profile: ${AWS_PROFILE}) …"
  echo
  RAW_OUTPUT=$(
    AWS_PROFILE="${AWS_PROFILE}" \
    GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS:-}" \
    "${TOFU_LAYER_RUN}" "${LAYER}" "${WORKSPACE}" output 2>/dev/null
  ) || die "Failed to fetch tofu outputs for layer '${LAYER}'."

  LAYER_JSON=$(echo "${RAW_OUTPUT}" | awk '/^\{/{found=1} found{print}')
  [[ -n "${LAYER_JSON}" ]] || die "Could not parse JSON from tofu outputs. Run with 2>&1 to debug."

  AWS_INSTANCES_JSON=$(echo "${LAYER_JSON}" | jq '.aws_instances.value // empty')
  [[ -n "${AWS_INSTANCES_JSON}" && "${AWS_INSTANCES_JSON}" != "null" ]] \
    || die "Output 'aws_instances' not found in layer '${LAYER}'. Choose a layer that exposes AWS compute outputs."

  VM_COUNT=$(echo "${AWS_INSTANCES_JSON}" | jq 'length')
  [[ "${VM_COUNT}" -gt 0 ]] || die "No AWS instances found in layer '${LAYER}' outputs."

  echo -e "${YELLOW}── AWS Target (from layer outputs) ───────────────────────${NC}"
  if [[ "${VM_COUNT}" -eq 1 ]]; then
    VM_NAME=$(echo "${AWS_INSTANCES_JSON}" | jq -r '.[0].name')
    info "Auto-selected instance : ${VM_NAME}"
  else
    VM_NAMES=()
    while IFS= read -r name; do VM_NAMES+=("$name"); done \
      < <(echo "${AWS_INSTANCES_JSON}" | jq -r '.[].name')
    prompt_choice VM_NAME "Target instance" "${PREV_VM_NAME:-${VM_NAMES[0]}}" "${VM_NAMES[@]}"
  fi

  TARGET_EXTERNAL=$(echo "${AWS_INSTANCES_JSON}" | jq -r --arg n "${VM_NAME}" \
    '.[] | select(.name == $n) | .external_ip // empty')
  TARGET_PRIVATE=$(echo "${AWS_INSTANCES_JSON}" | jq -r --arg n "${VM_NAME}" \
    '.[] | select(.name == $n) | .ip // empty')

  if [[ -n "${TARGET_EXTERNAL}" && "${TARGET_EXTERNAL}" != "null" ]]; then
    HOST="${TARGET_EXTERNAL}"
    TARGET_NEEDS_JUMP="no"
    info "Public IP  : ${HOST}"
    [[ -n "${TARGET_PRIVATE}" && "${TARGET_PRIVATE}" != "null" ]] && info "Private IP : ${TARGET_PRIVATE}"
  elif [[ -n "${TARGET_PRIVATE}" && "${TARGET_PRIVATE}" != "null" ]]; then
    HOST="${TARGET_PRIVATE}"
    TARGET_NEEDS_JUMP="yes"
    warn "Instance '${VM_NAME}' has no public IP (private subnet). Using private IP ${HOST}; a jump host is required."
  else
    warn "Instance '${VM_NAME}' has no IP in outputs."
    prompt HOST "Host (IP or DNS) to connect to" "${PREV_HOST}"
  fi
  echo
else
  echo -e "${YELLOW}── Manual target ─────────────────────────────────────────${NC}"
  prompt HOST "Host (IP or DNS) to connect to" "${PREV_HOST}"
  echo
fi

# ── SSH credentials ───────────────────────────────────────────────────────────
echo -e "${YELLOW}── SSH ───────────────────────────────────────────────────${NC}"
# Default user: ubuntu (ubuntu-server-lts) or ec2-user (amazon-linux-2023).
prompt SSH_USER "Remote user" "${PREV_SSH_USER:-ubuntu}"
prompt SSH_KEY  "Path to SSH private key (.pem)" "${PREV_SSH_KEY:-${HOME}/.ssh/id_rsa}"
ensure_key SSH_KEY
echo

# ── Jump host (bastion) ─────────────────────────────────────────────────────────
# Reach a private-subnet VM by hopping through a public-subnet VM (bastion).
echo -e "${YELLOW}── Jump host (bastion) ───────────────────────────────────${NC}"
JUMP_DEFAULT="${PREV_USE_JUMP:-no}"
[[ "${TARGET_NEEDS_JUMP:-no}" == "yes" ]] && JUMP_DEFAULT="yes"
prompt_choice USE_JUMP "Connect via a jump host (public-subnet bastion)?" "${JUMP_DEFAULT}" "no" "yes"

if [[ "${USE_JUMP}" == "yes" ]]; then
  echo
  # In layer mode, offer instances that have a public IP as bastion candidates.
  if [[ "${MODE}" == "layer" && -n "${AWS_INSTANCES_JSON:-}" ]]; then
    BASTION_NAMES=()
    while IFS= read -r name; do BASTION_NAMES+=("$name"); done \
      < <(echo "${AWS_INSTANCES_JSON}" | jq -r '.[] | select(.external_ip != null and .external_ip != "") | .name')
    if [[ ${#BASTION_NAMES[@]} -gt 0 ]]; then
      prompt_choice BASTION_VM "Bastion instance (public subnet)" \
        "${PREV_BASTION_VM:-${BASTION_NAMES[0]}}" "${BASTION_NAMES[@]}"
      BASTION_HOST=$(echo "${AWS_INSTANCES_JSON}" | jq -r --arg n "${BASTION_VM}" \
        '.[] | select(.name == $n) | .external_ip')
      info "Bastion public IP : ${BASTION_HOST}"
    else
      warn "No instances with a public IP found in layer outputs."
      prompt BASTION_HOST "Bastion host (public IP or DNS)" "${PREV_BASTION_HOST}"
    fi
  else
    prompt BASTION_HOST "Bastion host (public IP or DNS)" "${PREV_BASTION_HOST}"
  fi

  prompt BASTION_USER "Bastion remote user" "${PREV_BASTION_USER:-ec2-user}"
  prompt BASTION_KEY  "Bastion SSH key (.pem)" "${PREV_BASTION_KEY:-${SSH_KEY}}"
  ensure_key BASTION_KEY
fi
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${YELLOW}── Summary ───────────────────────────────────────────────${NC}"
[[ -n "${VM_NAME}" ]] && echo "  Instance : ${VM_NAME}"
echo "  Host     : ${HOST}"
echo "  User     : ${SSH_USER}"
echo "  Key      : ${SSH_KEY}"
if [[ "${USE_JUMP:-no}" == "yes" ]]; then
  echo "  Via      : ${BASTION_USER}@${BASTION_HOST} (jump host)"
  echo "  Jump key : ${BASTION_KEY}"
fi
echo

PROXY_CMD="ssh -i ${BASTION_KEY:-} -W %h:%p -o StrictHostKeyChecking=accept-new ${BASTION_USER:-}@${BASTION_HOST:-}"
echo -e "  Command that will run:"
if [[ "${USE_JUMP:-no}" == "yes" ]]; then
  echo -e "  ${CYAN}ssh -i ${SSH_KEY} -o ProxyCommand=\"${PROXY_CMD}\" ${SSH_USER}@${HOST}${NC}"
else
  echo -e "  ${CYAN}ssh -i ${SSH_KEY} ${SSH_USER}@${HOST}${NC}"
fi
echo

read -r -p "$(echo -e "${CYAN}?${NC} Connect? [Y/n]: ")" CONFIRM
[[ "$(echo "${CONFIRM:-y}" | tr '[:upper:]' '[:lower:]')" == "n" ]] && { info "Aborted."; exit 0; }

# Save before connecting so values persist even if the session is long-lived.
save_config
success "Saved values to ${CONF_FILE}"
echo

# ── Connect ───────────────────────────────────────────────────────────────────
if [[ "${USE_JUMP:-no}" == "yes" ]]; then
  # Hop through the bastion: -W forwards the connection to HOST:22 from the
  # bastion. The bastion authenticates with BASTION_KEY; final hop uses SSH_KEY.
  exec ssh \
    -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o ProxyCommand="ssh -i ${BASTION_KEY} -W %h:%p -o StrictHostKeyChecking=accept-new ${BASTION_USER}@${BASTION_HOST}" \
    "${SSH_USER}@${HOST}"
else
  exec ssh \
    -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    "${SSH_USER}@${HOST}"
fi
