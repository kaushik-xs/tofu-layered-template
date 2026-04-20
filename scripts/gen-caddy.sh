#!/usr/bin/env bash
#
# gen-caddy.sh — Generate a Caddyfile from a compose.app-services.yml
#
# Usage (run from repo root):
#   ./scripts/gen-caddy.sh
#
# Reads:  docker-images/<group>/<env>/app_services/compose.app-services.yml
# Writes: docker-images/<group>/<env>/app_services/Caddyfile
#
# Multiple services can share the same domain — path-based routes are emitted
# as  handle /path/* { reverse_proxy ... }  blocks first; the catch-all
# reverse_proxy (if any) comes last inside the same site block.
#
# Compatible with bash 3.2+ (macOS default shell).
# Previous values are saved to ~/.config/caddy-gen/last.conf
#
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_IMAGES_DIR="${REPO_ROOT}/docker-images"

CONF_DIR="${HOME}/.config/caddy-gen"
CONF_FILE="${CONF_DIR}/last.conf"

# ── Saved values ──────────────────────────────────────────────────────────────
PREV_GROUP=""
PREV_ENV=""

load_config() {
  # shellcheck source=/dev/null
  [[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}" || true
}

save_config() {
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" << CONF
# caddy-gen — last used values (auto-generated, do not commit)
PREV_GROUP="${GROUP}"
PREV_ENV="${ENV}"
CONF
}

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Fake associative arrays (bash 3.2 compatible) ─────────────────────────────
# Keys are sanitized: hyphens and dots → underscores.
# Usage:
#   map_set  MAP_NAME  "key"  "value"
#   map_get  MAP_NAME  "key"          → prints the value (empty if unset)
#   map_isset MAP_NAME "key"          → returns 0 if set and non-empty, 1 otherwise
_map_key() { echo "$1" | tr '.-' '__' | tr '-' '_'; }

map_set() {
  local _m="$1" _k; _k="$(_map_key "$2")"
  eval "_MAP_${_m}_${_k}=\"\$3\""
}

map_get() {
  local _m="$1" _k; _k="$(_map_key "$2")"
  eval "printf '%s' \"\${_MAP_${_m}_${_k}:-}\""
}

map_isset() {
  local _val; _val="$(map_get "$1" "$2")"
  [[ -n "$_val" ]]
}

# ── Prompt helpers ─────────────────────────────────────────────────────────────
prompt() {
  local var_name="$1" prompt_text="$2" default="${3:-}" value=""
  [[ -n "$default" ]] && prompt_text="${prompt_text} [${default}]"
  read -r -p "$(echo -e "${CYAN}?${NC} ${prompt_text}: ")" value
  [[ -z "$value" && -n "$default" ]] && value="$default"
  [[ -z "$value" ]] && die "Value for '${var_name}' is required."
  printf -v "$var_name" '%s' "$value"
}

prompt_optional() {
  local var_name="$1" prompt_text="$2" default="${3:-}" value=""
  [[ -n "$default" ]] && prompt_text="${prompt_text} [${default}]"
  read -r -p "$(echo -e "${CYAN}?${NC} ${prompt_text}: ")" value
  [[ -z "$value" ]] && value="$default"
  printf -v "$var_name" '%s' "$value"
}

prompt_yn() {
  local var_name="$1" prompt_text="$2" default="${3:-n}" display="y/n" value=""
  [[ "$default" == "y" ]] && display="Y/n"
  [[ "$default" == "n" ]] && display="y/N"
  read -r -p "$(echo -e "${CYAN}?${NC} ${prompt_text} [${display}]: ")" value
  value="$(echo "${value:-$default}" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "y" || "$value" == "n" ]] || die "Please answer y or n."
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

# ── Parse services from compose.app-services.yml ──────────────────────────────
# Prints lines of the form "service_name:port"
#
# Uses ${line:offset:len} substring checks throughout — avoids \{ \} and {n}
# quantifiers that are unreliable in macOS bash 3.2 / BSD regex engine.
parse_services() {
  local compose_file="$1"
  local current_svc="" container_name="" in_ports=0 line host_port portspec

  while IFS= read -r line; do

    # ── Service name: starts with "  " (2 sp), non-space 3rd char, ends ":" ──
    if [[ "${line:0:2}" == "  " && "${line:2:1}" != " " && "${line: -1}" == ":" ]]; then
      if [[ "$line" =~ ^[[:space:]][[:space:]]([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
        current_svc="${BASH_REMATCH[1]}"
        container_name=""
        in_ports=0
      fi
      continue
    fi

    [[ -z "$current_svc" ]] && continue

    # ── Property keys at 4-space indent ───────────────────────────────────────
    if [[ "${line:0:4}" == "    " && "${line:4:1}" != " " ]]; then
      if [[ "$line" == "    ports:" ]]; then
        in_ports=1
      else
        in_ports=0
        # Capture container_name value:  "    container_name: <value>"
        if [[ "${line:0:19}" == "    container_name:" ]]; then
          container_name="${line#*: }"
          container_name="${container_name#"${container_name%%[! ]*}"}"  # ltrim
        fi
      fi
      continue
    fi

    [[ $in_ports -eq 0 ]] && continue

    # ── Port entry: "      - ..." (6 spaces then dash) ────────────────────────
    if [[ "${line:0:8}" == "      - " ]]; then
      portspec="${line#*- }"
      portspec="${portspec//\"/}"

      if [[ "$portspec" =~ :-([0-9][0-9]*) ]]; then
        host_port="${BASH_REMATCH[1]}"
      elif [[ "$portspec" =~ ^([0-9][0-9]*): ]]; then
        host_port="${BASH_REMATCH[1]}"
      else
        continue
      fi

      echo "${current_svc}:${host_port}:${container_name}"
      in_ports=0
    fi

  done < "$compose_file"
}

# ── Print unique domains in EXPOSE_SVCS order ─────────────────────────────────
unique_domains() {
  local seen="" svc d
  for svc in "${EXPOSE_SVCS[@]}"; do
    d="$(map_get SVC_DOMAIN "$svc")"
    if [[ ":${seen}:" != *":${d}:"* ]]; then
      echo "$d"
      seen="${seen}:${d}"
    fi
  done
}

# ── Write one Caddy site block ────────────────────────────────────────────────
# Route data is stored per-domain:
#   DOMAIN_ROUTE_COUNT  domain  → number of path routes
#   DOMAIN_ROUTE_PATH_N domain  → path prefix for route N
#   DOMAIN_ROUTE_SVC_N  domain  → service name for route N
#   DOMAIN_CATCHALL_SVC domain  → catch-all service name (empty = none)
gen_site_block() {
  local domain="$1" is_first="$2"
  local log_file="/var/log/caddy/${domain}.access.log"
  local _c _pi _path _svc _catchall

  _c="$(map_get DOMAIN_ROUTE_COUNT "$domain")"
  _catchall="$(map_get DOMAIN_CATCHALL_SVC "$domain")"

  printf '%s {\n' "$domain"

  # Path-based handle blocks first
  if [[ -n "$_c" && "$_c" -gt 0 ]]; then
    _pi=1
    while [[ $_pi -le $_c ]]; do
      _path="$(map_get "DOMAIN_ROUTE_PATH_${_pi}" "$domain")"
      _svc="$(map_get "DOMAIN_ROUTE_SVC_${_pi}" "$domain")"
      printf '\thandle %s* {\n' "$_path"
      printf '\t\treverse_proxy localhost:%s\n' "$(map_get SVC_PORT "$_svc")"
      printf '\t}\n'
      _pi=$((_pi + 1))
    done
  fi

  # Catch-all last
  if [[ -n "$_catchall" ]]; then
    printf '\treverse_proxy localhost:%s\n' "$(map_get SVC_PORT "$_catchall")"
  fi

  # Log block
  printf '\tlog {\n'
  if [[ "$is_first" == "y" ]]; then
    printf '\t\toutput file %s {\n' "$log_file"
    printf '\t\t\troll_size 10MiB\n'
    printf '\t\t\troll_keep 7\n'
    printf '\t\t\troll_keep_for 168h\n'
    printf '\t\t}\n'
  else
    printf '\t\toutput file %s\n' "$log_file"
  fi
  printf '\t\tformat console\n'
  printf '\t\tlevel INFO\n'
  printf '\t}\n'
  printf '}\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
load_config

echo
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Caddy Config Generator                    ${NC}"
echo -e "${CYAN}============================================${NC}"
echo
[[ -f "${CONF_FILE}" ]] && info "Loaded saved values from ${CONF_FILE}"
echo "Answer each prompt — press Enter to accept the shown default."
echo

# ── Step 1: target ────────────────────────────────────────────────────────────
echo -e "${YELLOW}── Target ────────────────────────────────────────────────${NC}"
prompt GROUP "Group name"                            "${PREV_GROUP}"
prompt ENV   "Environment (e.g. qa, prod, staging)" "${PREV_ENV}"
echo

# ── Locate compose file ───────────────────────────────────────────────────────
APP_DIR="${DOCKER_IMAGES_DIR}/${GROUP}/${ENV}/app_services"
COMPOSE_FILE="${APP_DIR}/compose.app-services.yml"

[[ -f "${COMPOSE_FILE}" ]] \
  || die "compose.app-services.yml not found at: ${COMPOSE_FILE}"

info "Found: ${COMPOSE_FILE}"
echo

# ── Parse services ────────────────────────────────────────────────────────────
RAW_SERVICES=()
while IFS= read -r _line; do
  RAW_SERVICES+=("$_line")
done < <(parse_services "${COMPOSE_FILE}")

[[ ${#RAW_SERVICES[@]} -gt 0 ]] \
  || die "No services with port mappings found in ${COMPOSE_FILE}"

# Store port and container name for every parsed service
for entry in "${RAW_SERVICES[@]}"; do
  _rs_svc="${entry%%:*}"
  _rs_rest="${entry#*:}"
  _rs_port="${_rs_rest%%:*}"
  _rs_cname="${_rs_rest#*:}"
  map_set SVC_PORT      "$_rs_svc" "$_rs_port"
  map_set SVC_CONTAINER "$_rs_svc" "$_rs_cname"
done

echo -e "${YELLOW}── Services found ────────────────────────────────────────${NC}"
for entry in "${RAW_SERVICES[@]}"; do
  _rs_svc="${entry%%:*}"
  _rs_rest="${entry#*:}"; _rs_port="${_rs_rest%%:*}"; _rs_cname="${_rs_rest#*:}"
  echo -e "  ${BOLD}•${NC} ${_rs_svc}  (${_rs_cname}, port ${_rs_port})"
done
echo

# ── Step 2: select services and assign domains ────────────────────────────────
EXPOSE_SVCS=()

echo -e "${YELLOW}── Select services & assign domains ──────────────────────${NC}"
echo -e "  Services sharing the same domain will be configured together next."
echo

for entry in "${RAW_SERVICES[@]}"; do
  svc="${entry%%:*}"
  _rest="${entry#*:}"; port="${_rest%%:*}"; cname="${_rest#*:}"

  echo -e "  ${BOLD}── ${svc}${NC}  (${cname}, port ${port})"

  prompt_yn _expose "  Expose via reverse proxy?" "y"
  if [[ "$_expose" == "n" ]]; then
    echo; continue
  fi

  _pk="${svc//-/_}"
  eval "_prev_domain=\"\${PREV_DOMAIN_${_pk}:-}\""
  prompt _domain "  Domain (e.g. app.example.com)" "${_prev_domain}"

  EXPOSE_SVCS+=("$svc")
  map_set SVC_DOMAIN "$svc" "$_domain"

  echo
done

[[ ${#EXPOSE_SVCS[@]} -gt 0 ]] || { warn "No services selected for exposure. Exiting."; exit 0; }

# ── Step 3: configure routing per domain ──────────────────────────────────────
# Group exposed services by domain and ask path/catch-all for each.
echo -e "${YELLOW}── Configure routing per domain ──────────────────────────${NC}"
echo -e "  Each service can be a catch-all or handle a specific path prefix."
echo -e "  Path-based routes are emitted as  handle /path/* { ... }  first;"
echo -e "  the catch-all reverse_proxy (if any) comes last in the block."
echo

# Collect domains into an array first — avoids stdin being redirected away
# from the terminal when prompts run inside the loop.
ALL_DOMAINS=()
while IFS= read -r _d; do
  ALL_DOMAINS+=("$_d")
done < <(unique_domains)

for domain in "${ALL_DOMAINS[@]}"; do
  # Collect services assigned to this domain
  _domain_svcs=()
  for svc in "${EXPOSE_SVCS[@]}"; do
    [[ "$(map_get SVC_DOMAIN "$svc")" == "$domain" ]] && _domain_svcs+=("$svc")
  done
  _svc_count="${#_domain_svcs[@]}"

  _dk="$(echo "$domain" | tr '.-' '__')"   # safe key for saved values

  echo -e "  ${BOLD}Domain: ${domain}${NC}"
  if [[ $_svc_count -gt 0 ]]; then
    for svc in "${_domain_svcs[@]}"; do
      echo "    • ${svc}  ($(map_get SVC_CONTAINER "$svc"), port $(map_get SVC_PORT "$svc"))"
    done
  fi
  echo

  # Build a full service menu from ALL compose services (not domain-scoped)
  # so any service can be pointed to from any path route.
  _all_svc_keys=()
  _all_svc_opts=()
  for entry in "${RAW_SERVICES[@]}"; do
    _as="${entry%%:*}"
    _all_svc_keys+=("$_as")
    _all_svc_opts+=("${_as}  ($(map_get SVC_CONTAINER "$_as"), port $(map_get SVC_PORT "$_as"))")
  done

  # ── How many path-based routes? ─────────────────────────────────────────────
  eval "_prev_rcount=\"\${PREV_ROUTE_COUNT_${_dk}:-0}\""
  prompt _rcount "  How many path-based routes for ${domain}?" "${_prev_rcount}"
  [[ "$_rcount" =~ ^[0-9][0-9]*$ ]] || die "Route count must be a non-negative integer."
  map_set DOMAIN_ROUTE_COUNT "$domain" "$_rcount"

  # ── Configure each path route ────────────────────────────────────────────────
  if [[ "$_rcount" -gt 0 ]]; then
    echo
    _pi=1
    while [[ $_pi -le $_rcount ]]; do
      echo -e "  ${BOLD}Path route #${_pi}${NC}"

      eval "_prev_pi_path=\"\${PREV_ROUTE_PATH_${_pi}_${_dk}:-/}\""
      prompt_optional _ri_path "  Path prefix (e.g. /api/v1/)" "${_prev_pi_path}"
      [[ "$_ri_path" == /* ]] || _ri_path="/${_ri_path}"
      map_set "DOMAIN_ROUTE_PATH_${_pi}" "$domain" "$_ri_path"

      eval "_prev_pi_svc_idx=\"\${PREV_ROUTE_SVC_IDX_${_pi}_${_dk}:-1}\""
      prompt_choice _ri_svc_idx "  Service to handle this path" "${_prev_pi_svc_idx}" \
        "${_all_svc_opts[@]}"

      _ri_svc="${_all_svc_keys[$((_ri_svc_idx - 1))]}"
      map_set "DOMAIN_ROUTE_SVC_${_pi}" "$domain" "$_ri_svc"

      echo
      _pi=$((_pi + 1))
    done
  fi

  # ── Default (catch-all) reverse proxy ────────────────────────────────────────
  _catchall_opts=("None — no default reverse proxy")
  for entry in "${RAW_SERVICES[@]}"; do
    _as="${entry%%:*}"
    _catchall_opts+=("${_as}  ($(map_get SVC_CONTAINER "$_as"), port $(map_get SVC_PORT "$_as"))")
  done

  if [[ "$_rcount" -gt 0 ]]; then
    eval "_prev_catchall_idx=\"\${PREV_CATCHALL_IDX_${_dk}:-2}\""
    _catchall_label="  Default reverse proxy (unmatched requests)"
  else
    eval "_prev_catchall_idx=\"\${PREV_CATCHALL_IDX_${_dk}:-1}\""
    _catchall_label="  Reverse proxy service (1 = none)"
  fi

  prompt_choice _catchall_idx "$_catchall_label" "${_prev_catchall_idx}" \
    "${_catchall_opts[@]}"

  if [[ "$_catchall_idx" -eq 1 ]]; then
    map_set DOMAIN_CATCHALL_SVC "$domain" ""
  else
    _catchall_svc="${_all_svc_keys[$((_catchall_idx - 2))]}"
    map_set DOMAIN_CATCHALL_SVC "$domain" "$_catchall_svc"
  fi

  echo

done

# ── Summary ───────────────────────────────────────────────────────────────────
CADDY_FILE="${APP_DIR}/Caddyfile"

echo -e "${YELLOW}── Summary ───────────────────────────────────────────────${NC}"
echo "  Group       : ${GROUP}"
echo "  Environment : ${ENV}"
echo "  Output file : ${CADDY_FILE}"
echo
echo "  Site blocks to write:"
while IFS= read -r domain; do
  echo -e "  ${BOLD}${domain}${NC}"
  _c="$(map_get DOMAIN_ROUTE_COUNT "$domain")"
  if [[ -n "$_c" && "$_c" -gt 0 ]]; then
    _pi=1
    while [[ $_pi -le $_c ]]; do
      _path="$(map_get "DOMAIN_ROUTE_PATH_${_pi}" "$domain")"
      _svc="$(map_get "DOMAIN_ROUTE_SVC_${_pi}" "$domain")"
      echo "      handle ${_path}*  → localhost:$(map_get SVC_PORT "$_svc")  (${_svc})"
      _pi=$((_pi + 1))
    done
  fi
  _catchall="$(map_get DOMAIN_CATCHALL_SVC "$domain")"
  if [[ -n "$_catchall" ]]; then
    echo "      catch-all       → localhost:$(map_get SVC_PORT "$_catchall")  (${_catchall})"
  fi
done < <(unique_domains)
echo

read -r -p "$(echo -e "${CYAN}?${NC} Proceed? [y/N]: ")" CONFIRM
[[ "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" == "y" ]] \
  || { info "Aborted."; exit 0; }

# ── Write Caddyfile ───────────────────────────────────────────────────────────
echo
info "Generating Caddyfile …"

{
  _first_domain="y"
  while IFS= read -r domain; do
    gen_site_block "$domain" "$_first_domain"
    printf '\n'
    _first_domain="n"
  done < <(unique_domains)
} > "${CADDY_FILE}"

success "Written: ${CADDY_FILE}"

# ── Append Caddy targets to Makefile ─────────────────────────────────────────
MAKEFILE="${APP_DIR}/Makefile"

if [[ -f "${MAKEFILE}" ]]; then
  if grep -q "caddy-config" "${MAKEFILE}" 2>/dev/null; then
    info "Caddy targets already present in ${MAKEFILE} — skipping."
  else
    info "Appending Caddy targets to ${MAKEFILE} …"
    printf '\ncaddy-config:\n\tsudo cp Caddyfile /etc/caddy/Caddyfile\n' >> "${MAKEFILE}"
    printf '\ncaddy-start:\n\tsudo systemctl start caddy\n' >> "${MAKEFILE}"
    printf '\ncaddy-stop:\n\tsudo systemctl stop caddy\n' >> "${MAKEFILE}"
    printf '\ncaddy-restart:\n\tsudo systemctl restart caddy\n' >> "${MAKEFILE}"
    printf '\ncaddy-reload:\n\tsudo systemctl reload caddy\n' >> "${MAKEFILE}"
    success "Appended Caddy targets to ${MAKEFILE}"
  fi
else
  warn "No Makefile found at ${MAKEFILE} — skipping Makefile update."
fi

# ── Persist config ────────────────────────────────────────────────────────────
save_config

{
  # Per-service: domain assignment
  for svc in "${EXPOSE_SVCS[@]}"; do
    key="${svc//-/_}"
    echo "PREV_DOMAIN_${key}=\"$(map_get SVC_DOMAIN "$svc")\""
  done
  # Per-domain: route configuration
  while IFS= read -r domain; do
    _dk="$(echo "$domain" | tr '.-' '__')"
    _c="$(map_get DOMAIN_ROUTE_COUNT "$domain")"
    echo "PREV_ROUTE_COUNT_${_dk}=\"${_c}\""
    if [[ -n "$_c" && "$_c" -gt 0 ]]; then
      _pi=1
      while [[ $_pi -le $_c ]]; do
        echo "PREV_ROUTE_PATH_${_pi}_${_dk}=\"$(map_get "DOMAIN_ROUTE_PATH_${_pi}" "$domain")\""
        # Save 1-based index into the full RAW_SERVICES list
        _rsvc="$(map_get "DOMAIN_ROUTE_SVC_${_pi}" "$domain")"
        _ridx=1
        for entry in "${RAW_SERVICES[@]}"; do
          [[ "${entry%%:*}" == "$_rsvc" ]] && break
          _ridx=$((_ridx + 1))
        done
        echo "PREV_ROUTE_SVC_IDX_${_pi}_${_dk}=\"${_ridx}\""
        _pi=$((_pi + 1))
      done
    fi
    _catchall="$(map_get DOMAIN_CATCHALL_SVC "$domain")"
    if [[ -n "$_catchall" ]]; then
      # Index in catch-all menu: option 1 = None, options 2..N = RAW_SERVICES
      _cidx=2
      for entry in "${RAW_SERVICES[@]}"; do
        [[ "${entry%%:*}" == "$_catchall" ]] && break
        _cidx=$((_cidx + 1))
      done
      echo "PREV_CATCHALL_IDX_${_dk}=\"${_cidx}\""
    else
      echo "PREV_CATCHALL_IDX_${_dk}=\"1\""
    fi
  done < <(unique_domains)
} >> "${CONF_FILE}"

success "Saved values to ${CONF_FILE}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Done!                                     ${NC}"
echo -e "${GREEN}============================================${NC}"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. On the app VM, in the deploy directory:"
echo "       make caddy-config    # copies Caddyfile to /etc/caddy/Caddyfile"
echo "       make caddy-reload    # reloads Caddy without downtime"
echo "     Or for a full restart:"
echo "       make caddy-restart"
echo "  2. Caddy will auto-provision TLS for all configured domains"
echo
