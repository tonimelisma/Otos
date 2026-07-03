#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-summary}"
APP_ID="net.melisma.Otos"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DIR="$HOME/Library/Application Support/$APP_ID/Diagnostics"
LEGACY_FILE="$DEFAULT_DIR/catalog-diagnostics.jsonl"
OUTPUT_DIR="$ROOT_DIR/build/Diagnostics"

usage() {
  echo "usage: $0 [path|summary|check]" >&2
}

latest_diagnostics_file() {
  local latest
  latest="$(ls -t "$DEFAULT_DIR"/catalog-diagnostics-*.jsonl 2>/dev/null | head -n 1 || true)"
  if [[ -n "$latest" ]]; then
    echo "$latest"
  else
    echo "$LEGACY_FILE"
  fi
}

DIAGNOSTICS_FILE="${OTOS_CATALOG_DIAGNOSTICS_FILE:-$(latest_diagnostics_file)}"

diagnostic_count() {
  local pattern="$1"
  if [[ -f "$DIAGNOSTICS_FILE" ]]; then
    grep -c "$pattern" "$DIAGNOSTICS_FILE" || true
  else
    echo 0
  fi
}

diagnostic_field_max() {
  local pattern="$1"
  local field="$2"
  if [[ ! -f "$DIAGNOSTICS_FILE" ]]; then
    echo 0
    return
  fi

  awk -v pattern="$pattern" -v field="$field" '
    $0 ~ pattern {
      key = "\"" field "\":\""
      start = index($0, key)
      if (start > 0) {
        value = substr($0, start + length(key))
        sub(/".*/, "", value)
        if (value ~ /^[0-9]+$/ && value + 0 > max) {
          max = value + 0
        }
      }
    }
    END { print max + 0 }
  ' "$DIAGNOSTICS_FILE"
}

diagnostic_field_equals_count() {
  local pattern="$1"
  local field="$2"
  local expected="$3"
  if [[ ! -f "$DIAGNOSTICS_FILE" ]]; then
    echo 0
    return
  fi

  awk -v pattern="$pattern" -v field="$field" -v expected="$expected" '
    $0 ~ pattern {
      key = "\"" field "\":\""
      start = index($0, key)
      if (start > 0) {
        value = substr($0, start + length(key))
        sub(/".*/, "", value)
        if (value == expected) {
          count += 1
        }
      }
    }
    END { print count + 0 }
  ' "$DIAGNOSTICS_FILE"
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
    echo "scan issue max count: $(diagnostic_field_max '\"operation\":\"catalog.scan\".*\"phase\":\"error\"' issueCount)"
    echo "scan batches: $(diagnostic_count '\"operation\":\"catalog.scan.batch\"')"
    echo "stale scan callbacks ignored: $(diagnostic_count '\"operation\":\"catalog.scan.staleCallback\"')"
    echo "skipped packages: $(diagnostic_count '\"operation\":\"catalog.scan.skippedPackage\"')"
    echo "skipped non-media summaries: $(diagnostic_count '\"operation\":\"catalog.scan.skippedNonMedia\"')"
    echo "filesystem event schedules: $(diagnostic_count '\"operation\":\"catalog.filesystemEvent\".*\"phase\":\"schedule\"')"
    echo "filesystem event drops: $(diagnostic_count '\"operation\":\"catalog.filesystemEvent\".*\"phase\":\"drop\"')"
    echo "startup callers coalesced: $(diagnostic_count '\"operation\":\"catalog.start\".*\"phase\":\"coalesced\"')"
    echo "window projections: $(diagnostic_count '\"operation\":\"catalog.projection.window\"')"
    echo "window projection worst totalMs: $(diagnostic_field_max '\"operation\":\"catalog.projection.window\"' totalMs)"
    echo "window projection worst storeReadMs: $(diagnostic_field_max '\"operation\":\"catalog.projection.window\"' storeReadMs)"
    echo "window projection worst assetOrderQueryMs: $(diagnostic_field_max '\"operation\":\"catalog.projection.window\"' assetOrderQueryMs)"
    echo "window projection detail refreshes: $(diagnostic_field_equals_count '\"operation\":\"catalog.projection.window\"' detailRefreshChanged true)"
    echo "ordered-ID queries: $(diagnostic_count '\"operation\":\"catalog.store.query.order\"')"
    echo "ordered-ID query worst queryMs: $(diagnostic_field_max '\"operation\":\"catalog.store.query.order\"' queryMs)"
    echo "ordered-ID query max count: $(diagnostic_field_max '\"operation\":\"catalog.store.query.order\"' count)"
    echo "tile-detail queries: $(diagnostic_count '\"operation\":\"catalog.store.query.tileDetail\"')"
    echo "tile-detail query worst queryMs: $(diagnostic_field_max '\"operation\":\"catalog.store.query.tileDetail\"' queryMs)"
    echo "tile-detail query max requested: $(diagnostic_field_max '\"operation\":\"catalog.store.query.tileDetail\"' requested)"
    echo "tile-detail query max returned: $(diagnostic_field_max '\"operation\":\"catalog.store.query.tileDetail\"' returned)"
    echo "enrichment-candidate queries: $(diagnostic_count '\"operation\":\"catalog.store.query.enrichment\"')"
    echo "enrichment-candidate query worst queryMs: $(diagnostic_field_max '\"operation\":\"catalog.store.query.enrichment\"' queryMs)"
    echo "enrichment-candidate query max returned: $(diagnostic_field_max '\"operation\":\"catalog.store.query.enrichment\"' returned)"
    echo "metadata queries: $(diagnostic_count '\"operation\":\"catalog.store.query.metadata\"')"
    echo "metadata query worst queryMs: $(diagnostic_field_max '\"operation\":\"catalog.store.query.metadata\"' queryMs)"
    echo "main run loop stalls: $(diagnostic_count '\"operation\":\"ui.mainRunLoop.stall\"')"
    echo "main run loop worst stallMs: $(diagnostic_field_max '\"operation\":\"ui.mainRunLoop.stall\"' stallMs)"
    echo "library availability changes: $(diagnostic_count '\"operation\":\"catalog.library.availability\"')"
    echo "library ensures: $(diagnostic_count '\"operation\":\"catalog.library.ensure\".*\"phase\":\"start\"')"
    echo "library ensure existing roots: $(diagnostic_count '\"operation\":\"catalog.library.ensure\".*\"phase\":\"exists\"')"
    echo "library ensure inserts: $(diagnostic_count '\"operation\":\"catalog.library.ensure\".*\"phase\":\"finish\"')"
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
