#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-summary}"
APP_ID="net.melisma.Otos"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_FILE="$HOME/Library/Application Support/$APP_ID/Diagnostics/catalog-diagnostics.jsonl"
DIAGNOSTICS_FILE="${OTOS_CATALOG_DIAGNOSTICS_FILE:-$DEFAULT_FILE}"
OUTPUT_DIR="$ROOT_DIR/build/Diagnostics"

usage() {
  echo "usage: $0 [path|summary|check]" >&2
}

diagnostic_count() {
  local pattern="$1"
  if [[ -f "$DIAGNOSTICS_FILE" ]]; then
    grep -c "$pattern" "$DIAGNOSTICS_FILE" || true
  else
    echo 0
  fi
}

write_summary() {
  local output_file="$1"
  local line_count
  line_count="$(wc -l < "$DIAGNOSTICS_FILE" | tr -d ' ')"

  {
    echo "Catalog diagnostics"
    echo "source: $DIAGNOSTICS_FILE"
    echo "events: $line_count"
    echo "scan starts: $(diagnostic_count '\"operation\":\"catalog.scan\".*\"phase\":\"start\"')"
    echo "scan finishes: $(diagnostic_count '\"operation\":\"catalog.scan\".*\"phase\":\"finish\"')"
    echo "scan errors: $(diagnostic_count '\"operation\":\"catalog.scan\".*\"phase\":\"error\"')"
    echo "scan issues: $(diagnostic_count '\"operation\":\"catalog.scan.issue\"')"
    echo "scan batches: $(diagnostic_count '\"operation\":\"catalog.scan.batch\"')"
    echo "skipped packages: $(diagnostic_count '\"operation\":\"catalog.scan.skippedPackage\"')"
    echo "window projections: $(diagnostic_count '\"operation\":\"catalog.projection.window\"')"
    echo "library availability changes: $(diagnostic_count '\"operation\":\"catalog.library.availability\"')"
    echo "library adds: $(diagnostic_count '\"operation\":\"catalog.library.add\".*\"phase\":\"finish\"')"
    echo "library removes: $(diagnostic_count '\"operation\":\"catalog.library.remove\".*\"phase\":\"finish\"')"
  } > "$output_file"
}

case "$MODE" in
  path)
    echo "$DIAGNOSTICS_FILE"
    ;;
  summary|check)
    if [[ ! -s "$DIAGNOSTICS_FILE" ]]; then
      echo "catalog diagnostics not found or empty: $DIAGNOSTICS_FILE" >&2
      exit 1
    fi

    mkdir -p "$OUTPUT_DIR"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    COPY_FILE="$OUTPUT_DIR/catalog-diagnostics-$TIMESTAMP.jsonl"
    SUMMARY_FILE="$OUTPUT_DIR/catalog-diagnostics-$TIMESTAMP.txt"
    cp "$DIAGNOSTICS_FILE" "$COPY_FILE"
    write_summary "$SUMMARY_FILE"
    cat "$SUMMARY_FILE"
    echo "jsonl: $COPY_FILE"
    echo "summary: $SUMMARY_FILE"
    ;;
  *)
    usage
    exit 2
    ;;
esac
