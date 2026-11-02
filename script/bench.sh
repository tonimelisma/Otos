#!/usr/bin/env bash
# Benchmarks (ADR 0043).
#
#   script/bench.sh run             Build, run the benchmark suite (OtosTests/BenchmarkTests),
#                                   print the results, and record them on HEAD when the tree
#                                   is clean.
#   script/bench.sh history [case]  Every recorded result, newest first, with the change in
#                                   instructions from the previous record on the same machine.
#
# Results are recorded as git notes on the commit they measured (refs/notes/benchmarks),
# one JSON object per case. Instructions retired is the number to compare: it barely moves
# under machine load, which wall time does several-fold. A run on a tree with uncommitted
# changes prints its results but records nothing, because no commit is what it measured.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTES_REF="refs/notes/benchmarks"
RESULTS_FILE="$ROOT_DIR/build/benchmarks/results.ndjson"

usage() {
  sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

print_results() {
  /usr/bin/python3 -I - "$1" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(f"{'case':<36} {'M instructions':>15} {'spread':>7} {'median ms':>10} {'min ms':>8}")
for row in rows:
    print(f"{row['name']:<36} {row['instructions'] / 1e6:>15.1f} {row['instructionSpread'] * 100:>6.1f}% "
          f"{row['medianMilliseconds']:>10.1f} {row['minimumMilliseconds']:>8.1f}")
PY
}

run() {
  source "$ROOT_DIR/script/lib/xcode.sh"
  source "$ROOT_DIR/script/lib/run-context.sh"
  otos_require_full_xcode
  local log_file
  log_file="$(otos_log_file "$ROOT_DIR" bench bench)"
  rm -f "$RESULTS_FILE"
  echo "op=bench phase=build log=$log_file"
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    build-for-testing > "$log_file" 2>&1 || {
    echo "op=bench phase=failed reason=build log=$log_file" >&2
    exit 1
  }
  echo "op=bench phase=run"
  # The scheme substitutes $(OTOS_BENCHMARK) into the test environment; xcodebuild
  # resolves it only from a trailing build-setting argument, not an inherited variable.
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$ROOT_DIR/build/DerivedData" \
    test-without-building \
    -only-testing:OtosTests/BenchmarkTests \
    OTOS_BENCHMARK=1 >> "$log_file" 2>&1 || {
    echo "op=bench phase=failed reason=test log=$log_file" >&2
    exit 1
  }
  if [[ ! -s "$RESULTS_FILE" ]]; then
    echo "op=bench phase=failed reason=noResults log=$log_file" >&2
    exit 1
  fi
  print_results "$RESULTS_FILE"

  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    echo "op=bench phase=notRecorded reason=uncommittedChanges"
    return
  fi
  local commit note
  commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  note="$(/usr/bin/python3 -I - "$RESULTS_FILE" "$commit" \
    "$(/usr/sbin/sysctl -n hw.model)" \
    "$(/usr/bin/sw_vers -productVersion)" \
    "$(/usr/bin/xcodebuild -version | head -n 1)" \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys
path, commit, machine, macos, xcode, measured = sys.argv[1:7]
for line in open(path):
    if line.strip():
        row = json.loads(line)
        row.update(commit=commit, machine=machine, macOS=macos, xcode=xcode,
                   configuration="Debug", measuredAt=measured)
        print(json.dumps(row, sort_keys=True))
PY
)"
  git -C "$ROOT_DIR" notes --ref="$NOTES_REF" append -m "$note" "$commit"
  echo "op=bench phase=recorded commit=$commit ref=$NOTES_REF"
}

history() {
  /usr/bin/python3 -I - "$ROOT_DIR" "$NOTES_REF" "${1:-}" <<'PY'
import json, subprocess, sys
root, ref, wanted = sys.argv[1:4]
def git(*args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=True).stdout
rows = []
for listing in git("notes", f"--ref={ref}", "list").splitlines():
    commit = listing.split()[1]
    for line in git("notes", f"--ref={ref}", "show", commit).splitlines():
        if line.startswith("{"):
            row = json.loads(line)
            if not wanted or row["name"] == wanted:
                rows.append(row)
rows.sort(key=lambda row: row["measuredAt"])
previous = {}
lines = []
for row in rows:
    key = (row["name"], row["machine"])
    before = previous.get(key)
    change = "" if before is None else "%+.1f%%" % ((row["instructions"] - before) / before * 100)
    previous[key] = row["instructions"]
    lines.append("%s  %s  %-36s %12.1fM %8s %9.1f ms  %s" % (
        row["measuredAt"][:10], row["commit"][:9], row["name"], row["instructions"] / 1e6,
        change, row["medianMilliseconds"], row["machine"]))
print("\n".join(reversed(lines)) if lines else "No benchmark results recorded.")
PY
}

case "${1:-}" in
  run) run ;;
  history) history "${2:-}" ;;
  *) usage; exit 2 ;;
esac
