#!/usr/bin/env bash
#
# main.sh — Interactive menu for opentofu-nuke scripts
#
# Usage (run from repo root):
#   ./main.sh
#
# Presents an infinitely-running menu of all interactive scripts.
# Press 0 or Ctrl-C to exit.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TERM="${TERM:-xterm-256color}"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Menu registry ─────────────────────────────────────────────────────────────
# Each entry: "Category|Label|script/path.sh"
MENU_ITEMS=(
  "Docker|Docker Compose Generator|scripts/gen-compose.sh"
  "AWS   |S3 Bucket Migration|scripts/migration/aws/s3-bucket-migrate.sh"
  "GCP   |Cloud SQL Export|scripts/migration/gcp/cloudsql-export.sh"
  "GCP   |PostgreSQL VM Import|scripts/migration/gcp/vm-import.sh"
)

# ── Draw menu ─────────────────────────────────────────────────────────────────
draw_menu() {
  clear
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║           opentofu-nuke  ·  Script Hub           ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"

  local i=1
  local prev_cat=""
  for item in "${MENU_ITEMS[@]}"; do
    local cat label
    cat="$(echo "$item"  | cut -d'|' -f1)"
    label="$(echo "$item" | cut -d'|' -f2)"

    if [[ "$cat" != "$prev_cat" ]]; then
      echo -e "  ${DIM}── ${cat} ──────────────────────────────────────${NC}"
      prev_cat="$cat"
    fi

    printf "  ${CYAN}%2d)${NC}  %s\n" "$i" "$label"
    i=$(( i + 1 ))
  done

  echo
  echo -e "  ${RED} 0)${NC}  Exit"
  echo
  echo -e "${DIM}  ──────────────────────────────────────────────────${NC}"
}

# ── Run a script, then pause ──────────────────────────────────────────────────
run_script() {
  local label="$1"
  local script="${REPO_ROOT}/$2"

  if [[ ! -f "$script" ]]; then
    echo -e "${RED}[ERROR]${NC} Script not found: ${script}" >&2
    return
  fi

  clear
  echo -e "${BOLD}${CYAN}  ── ${label} ──${NC}"
  echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo
  bash "$script" || true
  echo
  echo -e "${DIM}──────────────────────────────────────────────────────${NC}"
  read -r -p "$(echo -e "${CYAN}  Press Enter to return to menu…${NC}")" _
}

# ── Trap Ctrl-C for a clean exit ──────────────────────────────────────────────
trap 'echo; echo -e "${YELLOW}  Goodbye.${NC}"; echo; exit 0' INT TERM

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
  draw_menu

  read -r -p "$(echo -e "${CYAN}  Select option: ${NC}")" CHOICE || { echo; break; }

  # Exit
  if [[ "$CHOICE" == "0" ]]; then
    echo -e "\n${YELLOW}  Goodbye.${NC}\n"
    exit 0
  fi

  # Validate: must be a number in range 1..N
  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || \
     [[ "$CHOICE" -lt 1 ]] || \
     [[ "$CHOICE" -gt "${#MENU_ITEMS[@]}" ]]; then
    echo -e "\n${RED}  Invalid option '${CHOICE}'. Enter a number between 0 and ${#MENU_ITEMS[@]}.${NC}"
    sleep 1
    continue
  fi

  IDX=$(( CHOICE - 1 ))
  ITEM="${MENU_ITEMS[$IDX]}"
  LABEL="$(echo "$ITEM" | cut -d'|' -f2)"
  SCRIPT="$(echo "$ITEM" | cut -d'|' -f3)"

  run_script "$LABEL" "$SCRIPT"
done
