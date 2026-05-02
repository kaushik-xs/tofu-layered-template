#!/usr/bin/env bash
# =============================================================================
# backup_pg.sh  —  Generic interactive PostgreSQL backup for any Docker container
# Usage: ./backup_pg.sh
# =============================================================================

set -euo pipefail

# AWS S3 config (todo: create a profile for this)
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""
export AWS_DEFAULT_REGION="ap-south-1"

# todo: create a bucket for this
S3_BASE="s3://"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

prompt() {
  # prompt <var_name> <display_label> <default_value>
  local var_name="$1" label="$2" default="$3" input
  if [ -n "$default" ]; then
    read -rp "  ${label} [${default}]: " input
    input="${input:-$default}"
  else
    while true; do
      read -rp "  ${label}: " input
      [ -n "$input" ] && break
      echo "  ✗  This field is required."
    done
  fi
  printf -v "$var_name" '%s' "$input"
}

pick_s3_folder() {
  local folders=("new-framework" "aarohan-dev")
  echo ""
  echo "  Select S3 destination folder:"
  for i in "${!folders[@]}"; do
    echo "    $((i+1))) ${folders[$i]}"
  done
  echo "    $((${#folders[@]}+1))) custom"
  while true; do
    read -rp "  Choice [1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$((${#folders[@]}+1))" ]; then
      if [ "$choice" -le "${#folders[@]}" ]; then
        S3_FOLDER="${folders[$((choice-1))]}"
      else
        prompt S3_FOLDER "Custom folder name" ""
      fi
      break
    fi
    echo "  ✗  Invalid choice."
  done
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     PostgreSQL Docker Backup Utility         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Enter backup parameters (press Enter to accept defaults):"
echo ""

# ── Interactive prompts ───────────────────────────────────────────────────────
prompt CONTAINER  "Docker container name"  ""
prompt DB_NAME    "Database name"          ""
prompt DB_USER    "Database user"          "postgres"
prompt BACKUP_DIR "Backup directory path"  "/tmp/pg-backups"
pick_s3_folder

# ── Derived values ────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SAFE_DB=$(echo "$DB_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_')
BACKUP_FILE="${BACKUP_DIR}/${SAFE_DB}_${TIMESTAMP}.dump"
LOG_FILE="${BACKUP_DIR}/${SAFE_DB}_${TIMESTAMP}.log"

mkdir -p "$BACKUP_DIR"

# ── Summary & confirm ─────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────"
echo "  Container : $CONTAINER"
echo "  Database  : $DB_NAME"
echo "  User      : $DB_USER"
echo "  Output    : $BACKUP_FILE"
echo "  S3 dest   : ${S3_BASE}/${S3_FOLDER}/"
echo "──────────────────────────────────────────────"
echo ""
read -rp "Proceed with backup? [Y/n]: " GO
GO="${GO:-Y}"
[[ "$GO" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# ── Pre-flight ────────────────────────────────────────────────────────────────
touch "$LOG_FILE"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  log "ERROR: Container '${CONTAINER}' is not running. Aborting."
  exit 1
fi

log "Starting backup → ${BACKUP_FILE}"

# ── Dump (custom format — compressed, supports selective restore) ─────────────
docker exec "$CONTAINER" \
  pg_dump \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    --format=custom \
    --compress=9 \
    --no-password \
  > "$BACKUP_FILE"

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
log "Backup complete. Size: ${BACKUP_SIZE}"
log "File: ${BACKUP_FILE}"

# ── Checksum ──────────────────────────────────────────────────────────────────
sha256sum "$BACKUP_FILE" > "${BACKUP_FILE}.sha256"
log "SHA-256: $(cat "${BACKUP_FILE}.sha256")"

# ── Prune old backups for this DB (keep last 7) ───────────────────────────────
KEEP=7
mapfile -t DUMPS < <(ls -1t "${BACKUP_DIR}/${SAFE_DB}_"*.dump 2>/dev/null)
if [ "${#DUMPS[@]}" -gt "$KEEP" ]; then
  for old in "${DUMPS[@]:$KEEP}"; do
    log "Pruning old backup: ${old}"
    rm -f "$old" "${old}.sha256"
  done
fi

log "Done. Log: ${LOG_FILE}"

# ── Upload to S3 ──────────────────────────────────────────────────────────────
S3_DEST="${S3_BASE}/${S3_FOLDER}/"
log "Uploading backup to S3: ${S3_DEST}"

if ! command -v aws &>/dev/null; then
  log "ERROR: aws CLI not found. Skipping S3 upload. Install with: pip install awscli"
else
  aws s3 cp "$BACKUP_FILE"          "${S3_DEST}$(basename "$BACKUP_FILE")"          --no-progress
  aws s3 cp "${BACKUP_FILE}.sha256" "${S3_DEST}$(basename "${BACKUP_FILE}.sha256")" --no-progress
  log "S3 upload complete: ${S3_DEST}$(basename "$BACKUP_FILE")"
fi

echo ""
echo "✓ Backup successful: ${BACKUP_FILE}"
echo "✓ S3 destination   : ${S3_DEST}$(basename "$BACKUP_FILE")"