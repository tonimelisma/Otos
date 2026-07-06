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
    echo "scan batch worst writeMs: $(diagnostic_field_max '\"operation\":\"catalog.scan.batch\"' writeMs)"
    echo "scan batch worst waitMs: $(diagnostic_field_max '\"operation\":\"catalog.scan.batch\"' waitMs)"
    echo "scan batch worst execMs: $(diagnostic_field_max '\"operation\":\"catalog.scan.batch\"' execMs)"
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
    echo "structural applies: $(diagnostic_count '\"operation\":\"ui.mediaGrid.structuralApply\"')"
    echo "structural apply worst applyMs: $(diagnostic_field_max '\"operation\":\"ui.mediaGrid.structuralApply\"' applyMs)"
    echo "structural apply max visible detail requests: $(diagnostic_field_max '\"operation\":\"ui.mediaGrid.structuralApply\"' visibleDetailRequestCount)"
    echo "ordered-ID queries: $(diagnostic_count '\"operation\":\"catalog.store.query.order\"')"
    echo "ordered-ID query worst queryMs: $(diagnostic_field_max '\"operation\":\"catalog.store.query.order\"' queryMs)"
    echo "ordered-ID query max count: $(diagnostic_field_max '\"operation\":\"catalog.store.query.order\"' count)"
    echo "tile-detail queries: $(diagnostic_count '\"operation\":\"catalog.store.query.tileDetail\"')"
    echo "tile-detail query worst queryMs: $(diagnostic_field_max '\"operation\":\"catalog.store.query.tileDetail\"' queryMs)"
    echo "tile-detail query max requested: $(diagnostic_field_max '\"operation\":\"catalog.store.query.tileDetail\"' requested)"
    echo "tile-detail query max returned: $(diagnostic_field_max '\"operation\":\"catalog.store.query.tileDetail\"' returned)"
    echo "tile-detail query slow single-row records: $(diagnostic_field_equals_count '\"operation\":\"catalog.store.query.tileDetail\"' requested 1)"
    echo "grid counter records: $(diagnostic_count '\"operation\":\"ui.grid.counters\"')"
    echo "grid counter max watchdog total: $(diagnostic_field_max '\"operation\":\"ui.grid.counters\"' totalWatchdogCount)"
    echo "grid counter max cache hit rate permille: $(diagnostic_field_max '\"operation\":\"ui.grid.counters\"' totalCacheHitRatePermille)"
    echo "download lifecycle materialized: $(diagnostic_count '\"operation\":\"catalog.thumbnails.visibleLifecycle\".*\"phase\":\"materialized\"')"
    echo "download lifecycle failed: $(diagnostic_count '\"operation\":\"catalog.thumbnails.visibleLifecycle\".*\"phase\":\"materializationFailed\"')"
    echo "enrichment-candidate queries: $(diagnostic_count '\"operation\":\"catalog.store.query.enrichment\"')"
    echo "enrichment-candidate query worst queryMs: $(diagnostic_field_max '\"operation\":\"catalog.store.query.enrichment\"' queryMs)"
    echo "enrichment-candidate query max returned: $(diagnostic_field_max '\"operation\":\"catalog.store.query.enrichment\"' returned)"
    echo "enrichment batches: $(diagnostic_count '\"operation\":\"catalog.enrichment.batch\"')"
    echo "enrichment batch worst writeMs: $(diagnostic_field_max '\"operation\":\"catalog.enrichment.batch\"' writeMs)"
    echo "enrichment batch worst waitMs: $(diagnostic_field_max '\"operation\":\"catalog.enrichment.batch\"' waitMs)"
    echo "enrichment batch worst execMs: $(diagnostic_field_max '\"operation\":\"catalog.enrichment.batch\"' execMs)"
    echo "enrichment batch max attempted: $(diagnostic_field_max '\"operation\":\"catalog.enrichment.batch\"' attempted)"
    echo "wal samples: $(diagnostic_count '\"operation\":\"catalog.database.wal\"')"
    echo "wal sample max bytes: $(diagnostic_field_max '\"operation\":\"catalog.database.wal\"' walBytes)"
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

run_check_gates() {
  python3 - "$DIAGNOSTICS_FILE" <<'PY'
import json
import statistics
import sys
from collections import defaultdict

path = sys.argv[1]
events = []
with open(path, "r", encoding="utf-8") as handle:
    for line_number, line in enumerate(handle, start=1):
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError as error:
            print(f"catalog diagnostics check failed: invalid JSON on line {line_number}: {error}", file=sys.stderr)
            sys.exit(1)

failures = []

def field_int(event, name, default=None):
    value = event.get("fields", {}).get(name)
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default

def op(operation, phase=None):
    return [
        event for event in events
        if event.get("operation") == operation
        and (phase is None or event.get("phase") == phase)
    ]

counter_events = op("ui.grid.counters")
if not counter_events:
    failures.append("ui.grid.counters record missing")
else:
    watchdog_total = max(
        field_int(event, "totalWatchdogCount", field_int(event, "watchdogCount", 0)) or 0
        for event in counter_events
    )
    if watchdog_total != 0:
        failures.append(f"watchdog counter is {watchdog_total}, expected 0")

apply_values = [
    field_int(event, "applyMs")
    for event in op("ui.mediaGrid.structuralApply")
]
apply_values = [value for value in apply_values if value is not None]
if apply_values:
    apply_p50 = statistics.median(apply_values)
    apply_max = max(apply_values)
    if apply_p50 > 100:
        failures.append(f"structural apply p50 {apply_p50}ms exceeds 100ms")
    if apply_max > 200:
        failures.append(f"structural apply max {apply_max}ms exceeds 200ms")

stall_values = [
    field_int(event, "stallMs")
    for event in op("ui.mainRunLoop.stall")
]
stall_values = [value for value in stall_values if value is not None]
if stall_values:
    stall_p50 = statistics.median(stall_values)
    stall_max = max(stall_values)
    if stall_p50 > 200:
        failures.append(f"main-run-loop stall p50 {stall_p50}ms exceeds 200ms")
    if stall_max > 500:
        failures.append(f"main-run-loop stall max {stall_max}ms exceeds 500ms")

single_row_slow = [
    event for event in op("catalog.store.query.tileDetail")
    if event.get("fields", {}).get("requested") == "1"
]
if single_row_slow:
    failures.append(f"slow single-row tile-detail records present: {len(single_row_slow)}")

download_completions = [
    event for event in op("catalog.thumbnails.visibleLifecycle")
    if event.get("phase") in {"materialized", "materializationFailed"}
]
missing_download_fields = [
    event for event in download_completions
    if "rerequestCount" not in event.get("fields", {})
    or "requestToCompleteMs" not in event.get("fields", {})
]
if missing_download_fields:
    failures.append(
        "download completion records missing rerequestCount/requestToCompleteMs: "
        f"{len(missing_download_fields)}"
    )

timeline = defaultdict(list)
for index, event in enumerate(op("catalog.thumbnails.visibleLifecycle")):
    fields = event.get("fields", {})
    key = (fields.get("rootPath", ""), fields.get("relativePath", ""))
    if key[0] or key[1]:
        timeline[key].append((index, event.get("phase")))

stragglers = []
for key, phases in timeline.items():
    materialized_indices = [index for index, phase in phases if phase == "materialized"]
    if not materialized_indices:
        continue
    last_materialized = materialized_indices[-1]
    later_phases = [phase for index, phase in phases if index > last_materialized]
    if not any(phase in {"claimed", "dispatched", "generated", "batchAccepted", "batchPartiallyApplied"} for phase in later_phases):
        stragglers.append(key)

if stragglers:
    formatted = ", ".join("/".join(part for part in key if part) for key in stragglers[:5])
    failures.append(f"materialized lifecycle stragglers without re-claim: {formatted}")

if failures:
    print("catalog diagnostics check failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("catalog diagnostics check passed")
PY
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
    COPY_FILE="$OUTPUT_DIR/catalog-diagnostics-$TIMESTAMP-$$.jsonl"
    SUMMARY_FILE="$OUTPUT_DIR/catalog-diagnostics-$TIMESTAMP-$$.txt"
    cp "$DIAGNOSTICS_FILE" "$COPY_FILE"
    write_summary "$SUMMARY_FILE"
    cat "$SUMMARY_FILE"
    if [[ "$MODE" == "check" ]]; then
      run_check_gates
    fi
    echo "jsonl: $COPY_FILE"
    echo "summary: $SUMMARY_FILE"
    ;;
  *)
    usage
    exit 2
    ;;
esac
