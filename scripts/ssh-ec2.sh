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

# Refresh a stale host key. EC2 instances rebuilt by tofu (destroy/apply) keep their
# Elastic IP but get a brand-new SSH host key at first boot, so a cached known_hosts
# entry no longer matches and ssh aborts with "REMOTE HOST IDENTIFICATION HAS CHANGED".
# If a cached entry exists for HOST, show it and offer to drop it before connecting.
# Guarded by a prompt so we don't silently weaken MITM protection.
refresh_known_host() {
  local host="$1"
  [[ -z "${host}" ]] && return 0
  local known="${HOME}/.ssh/known_hosts"
  [[ -f "${known}" ]] || return 0
  ssh-keygen -F "${host}" -f "${known}" >/dev/null 2>&1 || return 0  # no cached entry

  warn "A host key for '${host}' is already cached in ${known}."
  warn "If this instance was rebuilt (tofu destroy/apply), the key changed and ssh will refuse to connect."
  local reply
  read -r -p "$(echo -e "${CYAN}?${NC} Remove the cached host key for ${host} and trust the new one? [y/N]: ")" reply
  if [[ "$(echo "${reply:-n}" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    ssh-keygen -R "${host}" -f "${known}" >/dev/null 2>&1 || true
    success "Removed cached host key for ${host}; it will be re-trusted on connect."
  else
    info "Keeping cached host key. If it has changed, the connection will fail."
  fi
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

# Fetch a layer's `aws_instances` output as JSON. Prints the JSON array on success,
# nothing on failure. Reuses AWS_PROFILE / WORKSPACE / GOOGLE_CREDENTIALS from the env.
# Used both for the SSH target layer and (cross-layer) for bastion candidates, since a
# private-subnet VM often lives in a `_data` layer while its public bastion is in the
# sibling runtime layer (e.g. project_data target → project bastion).
fetch_aws_instances() {
  local layer="$1" raw json
  raw=$(
    AWS_PROFILE="${AWS_PROFILE}" \
    GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS:-}" \
    "${TOFU_LAYER_RUN}" "${layer}" "${WORKSPACE}" output 2>/dev/null
  ) || return 1
  json=$(echo "${raw}" | awk '/^\{/{found=1} found{print}')
  [[ -n "${json}" ]] || return 1
  echo "${json}" | jq '.aws_instances.value // empty'
}

# Materialise the shared AWS compute private key from the networking layer state.
# Every repo-provisioned EC2 (bastion + private VMs) authenticates with the single key
# generated in the networking layer (tls_private_key.compute); the private half lives only
# in that layer's state, never on disk. This fetches it with -show-sensitive, writes it to a
# 0600 file under ~/.ssh, and prints that path on stdout. Status/log lines go to stderr so
# command substitution captures only the path. Returns non-zero (prints nothing) when the
# key output is absent (null) — e.g. a GCP-only networking deploy or a custom per-instance key.
KEY_CACHE_DIR="${HOME}/.ssh"
materialize_compute_key() {
  local raw json pem key_name out
  raw=$(
    AWS_PROFILE="${AWS_PROFILE}" \
    GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS:-}" \
    "${TOFU_LAYER_RUN}" networking "${WORKSPACE}" output -show-sensitive 2>/dev/null
  ) || return 1
  json=$(echo "${raw}" | awk '/^\{/{found=1} found{print}')
  [[ -n "${json}" ]] || return 1

  pem=$(echo "${json}" | jq -r '.aws_compute_private_key_pem.value // empty')
  key_name=$(echo "${json}" | jq -r '.aws_compute_key_pair_name.value // empty')
  [[ -n "${pem}" ]] || return 1   # key not generated (null) — nothing to write

  out="${KEY_CACHE_DIR}/tofu-${WORKSPACE}-aws-compute.pem"
  mkdir -p "${KEY_CACHE_DIR}"
  ( umask 077; printf '%s\n' "${pem}" > "${out}" )
  chmod 600 "${out}"
  info "Retrieved shared compute key '${key_name:-?}' from networking state → ${out}" >&2
  echo "${out}"
}

# Map a target layer to the sibling layer most likely to hold its public bastion:
# a `_data` layer pairs with its runtime layer (project_data → project). Other layers
# map to themselves.
bastion_sibling_layer() {
  local layer="$1"
  case "${layer}" in
    *_data) echo "${layer%_data}" ;;
    *)      echo "${layer}" ;;
  esac
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
  AWS_INSTANCES_JSON=$(fetch_aws_instances "${LAYER}") \
    || die "Failed to fetch tofu outputs for layer '${LAYER}'."
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

  # Auto-fetch the shared compute key from networking state so the SSH key prompt
  # below defaults to the real key instead of a guessed .pem. Best-effort: on failure
  # (no key generated, or networking state unreachable) we leave the saved default.
  info "Resolving shared SSH key from networking layer state …"
  if MANAGED_KEY="$(materialize_compute_key)"; then
    DEFAULT_SSH_KEY="${MANAGED_KEY}"
  else
    warn "Could not retrieve a shared compute key from networking state; falling back to saved/default key."
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
# Prefer the key auto-fetched from networking state (layer mode); else saved; else id_rsa.
prompt SSH_KEY  "Path to SSH private key (.pem)" "${DEFAULT_SSH_KEY:-${PREV_SSH_KEY:-${HOME}/.ssh/id_rsa}}"
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
  # The target layer (e.g. project_data) often has only private VMs, so fall back to
  # the sibling runtime layer (project) which holds the public bastion.
  BASTION_JSON="${AWS_INSTANCES_JSON:-}"
  if [[ "${MODE}" == "layer" ]]; then
    if [[ -z "$(echo "${BASTION_JSON:-}" | jq -r '.[] | select(.external_ip != null and .external_ip != "") | .name' 2>/dev/null)" ]]; then
      SIBLING_LAYER="$(bastion_sibling_layer "${LAYER}")"
      if [[ "${SIBLING_LAYER}" != "${LAYER}" ]]; then
        info "No public-IP VM in layer '${LAYER}'; checking sibling layer '${SIBLING_LAYER}' for a bastion …"
        SIBLING_JSON="$(fetch_aws_instances "${SIBLING_LAYER}" 2>/dev/null || true)"
        [[ -n "${SIBLING_JSON}" && "${SIBLING_JSON}" != "null" ]] && BASTION_JSON="${SIBLING_JSON}"
      fi
    fi
  fi

  if [[ "${MODE}" == "layer" && -n "${BASTION_JSON:-}" && "${BASTION_JSON}" != "null" ]]; then
    BASTION_NAMES=()
    while IFS= read -r name; do BASTION_NAMES+=("$name"); done \
      < <(echo "${BASTION_JSON}" | jq -r '.[] | select(.external_ip != null and .external_ip != "") | .name')
    if [[ ${#BASTION_NAMES[@]} -gt 0 ]]; then
      prompt_choice BASTION_VM "Bastion instance (public subnet)" \
        "${PREV_BASTION_VM:-${BASTION_NAMES[0]}}" "${BASTION_NAMES[@]}"
      BASTION_HOST=$(echo "${BASTION_JSON}" | jq -r --arg n "${BASTION_VM}" \
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

# Refresh stale host keys (rebuilt instances reuse their IP with a new host key).
[[ "${USE_JUMP:-no}" == "yes" ]] && refresh_known_host "${BASTION_HOST}"
refresh_known_host "${HOST}"
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
