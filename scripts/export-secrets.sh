#!/usr/bin/env bash
# Collects all .tfvars files (non-example) from every layer and all files from
# docker-images/, preserves the project directory structure, and produces a
# timestamped zip archive.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="opentofu-nuke-secrets_${TIMESTAMP}.zip"
STAGING_DIR="$(mktemp -d)"

cleanup() { rm -rf "${STAGING_DIR}"; }
trap cleanup EXIT

echo "Staging directory: ${STAGING_DIR}"
echo ""

# ── tfvars files (exclude .example files) ────────────────────────────────────
echo "Collecting tfvars files..."
while IFS= read -r -d '' src; do
  rel="${src#"${REPO_ROOT}/"}"
  dst="${STAGING_DIR}/${rel}"
  mkdir -p "$(dirname "${dst}")"
  cp "${src}" "${dst}"
  echo "  + ${rel}"
done < <(find "${REPO_ROOT}/layers" \
           -name "*.tfvars" \
           ! -name "*.tfvars.example" \
           -print0)

echo ""

# ── docker-images (skip .DS_Store) ───────────────────────────────────────────
echo "Collecting docker-images files..."
while IFS= read -r -d '' src; do
  rel="${src#"${REPO_ROOT}/"}"
  dst="${STAGING_DIR}/${rel}"
  mkdir -p "$(dirname "${dst}")"
  cp "${src}" "${dst}"
  echo "  + ${rel}"
done < <(find "${REPO_ROOT}/docker-images" \
           -type f \
           ! -name ".DS_Store" \
           -print0)

echo ""

# ── zip ───────────────────────────────────────────────────────────────────────
OUTPUT_PATH="${REPO_ROOT}/${ARCHIVE_NAME}"
(cd "${STAGING_DIR}" && zip -r "${OUTPUT_PATH}" .)
echo "Archive created: ${ARCHIVE_NAME}"
echo "Full path:       ${OUTPUT_PATH}"
