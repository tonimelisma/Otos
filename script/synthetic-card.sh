#!/usr/bin/env bash
set -euo pipefail

# A reproducible removable-volume seam for import-plan and erase verification.
# The images are deliberately created without the product's "Disk Image" device
# model, so the product's disk-image cleanup rule does not classify this harness
# as a catalog root to remove.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${OTOS_SYNTHETIC_CARD_STATE_DIR:-${TMPDIR:-/tmp}/otos-synthetic-card}"
EXFAT_IMAGE="$STATE_DIR/probe-exfat.dmg"
CASE_IMAGE="$STATE_DIR/probe-case-sensitive.dmg"
EXFAT_VOLUME="/Volumes/OTOSPROBE"
CASE_VOLUME="/Volumes/OTOSPROBECS"

usage() {
  cat <<'EOF'
usage: script/synthetic-card.sh create|attach|detach|destroy

create   create an ExFAT and a case-sensitive APFS test volume
attach   mount both volumes without opening Finder
detach   unmount both volumes
destroy  detach and remove only this harness's state directory
EOF
}

require_hdiutil() {
  command -v hdiutil >/dev/null 2>&1 || {
    echo "hdiutil is required on macOS" >&2
    exit 1
  }
}

create() {
  require_hdiutil
  mkdir -p "$STATE_DIR"
  [[ -e "$EXFAT_IMAGE" ]] || hdiutil create -quiet -size 32m -fs ExFAT -volname OTOSPROBE "$EXFAT_IMAGE"
  [[ -e "$CASE_IMAGE" ]] || hdiutil create -quiet -size 32m -fs 'Case-sensitive APFS' -volname OTOSPROBECS "$CASE_IMAGE"
  echo "Created synthetic card images in $STATE_DIR"
}

attach() {
  require_hdiutil
  [[ -e "$EXFAT_IMAGE" && -e "$CASE_IMAGE" ]] || {
    echo "Run create first" >&2
    exit 1
  }
  hdiutil attach -nobrowse -quiet "$EXFAT_IMAGE" >/dev/null
  hdiutil attach -nobrowse -quiet "$CASE_IMAGE" >/dev/null
  echo "Attached $EXFAT_VOLUME (case-insensitive ExFAT)"
  echo "Attached $CASE_VOLUME (case-sensitive APFS)"
}

detach() {
  require_hdiutil
  hdiutil detach "$EXFAT_VOLUME" >/dev/null 2>&1 || true
  hdiutil detach "$CASE_VOLUME" >/dev/null 2>&1 || true
  echo "Detached synthetic card volumes"
}

destroy() {
  detach
  if [[ "$STATE_DIR" != */otos-synthetic-card && "$STATE_DIR" != */otos-synthetic-card-* && "$STATE_DIR" != */otos-synthetic-card/* ]]; then
    echo "Refusing to destroy unexpected state directory: $STATE_DIR" >&2
    exit 1
  fi
  rm -rf "$STATE_DIR"
  echo "Destroyed synthetic card state at $STATE_DIR"
}

case "${1:-}" in
  create) create ;;
  attach) attach ;;
  detach) detach ;;
  destroy) destroy ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
