#!/usr/bin/env bash
# Benchmarks (ADR 0043).
#
#   script/bench.sh run             Build, run the benchmark suite (OtosTests/BenchmarkTests),
#                                   print the results, and record them on HEAD when the tree
#                                   is clean.
#   script/bench.sh history [case]  Every recorded result, newest first, with the change in
#                                   instructions from the previous record on the same machine.
#   script/bench.sh compare [base]  HEAD's record against base's (default: the merge base with
#                                   origin/main), measuring base first when it has no record.
#                                   Exits 3 when a case retired more than 2% more instructions
#                                   (OTOS_BENCH_FLAG_PERCENT): the owner decides whether it merges.
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
  sed -n '4,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# The newest record of each case for one commit on this machine, as JSON lines; empty
# when the commit has none.
records_for() {
  /usr/bin/python3 -I - "$ROOT_DIR" "$NOTES_REF" "$1" "$(/usr/sbin/sysctl -n hw.model)" <<'PY'
import json, subprocess, sys
root, ref, commit, machine = sys.argv[1:5]
shown = subprocess.run(["git", "-C", root, "notes", f"--ref={ref}", "show", commit], capture_output=True, text=True)
newest = {}
for line in shown.stdout.splitlines():
    if line.startswith("{"):
        row = json.loads(line)
        if row["machine"] == machine and row["configuration"] == "Debug":
            if row["name"] not in newest or row["measuredAt"] > newest[row["name"]]["measuredAt"]:
                newest[row["name"]] = row
for row in newest.values():
    print(json.dumps(row, sort_keys=True))
PY
}

compare() {
  local base head threshold
  threshold="${OTOS_BENCH_FLAG_PERCENT:-2}"
  head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  base="$(git -C "$ROOT_DIR" rev-parse "${1:-$(git -C "$ROOT_DIR" merge-base HEAD origin/main)}")"
  if [[ -z "$(records_for "$head")" ]]; then
    echo "op=bench phase=compareFailed reason=headNotRecorded commit=$head (run script/bench.sh run on a clean tree first)" >&2
    exit 1
  fi
  if [[ "$base" == "$head" ]]; then
    echo "op=bench phase=compareSkipped reason=headIsBase commit=$head"
    return
  fi
  if [[ -z "$(records_for "$base")" ]]; then
    if ! git -C "$ROOT_DIR" cat-file -e "$base:OtosTests/BenchmarkTests.swift" 2>/dev/null; then
      echo "op=bench phase=compareSkipped reason=baseHasNoBenchmarks base=$base"
      return
    fi
    # The base is measured in its own detached checkout, which records it like any run.
    local base_tree="$ROOT_DIR/build/bench-base"
    echo "op=bench phase=measureBase base=$base tree=$base_tree"
    git -C "$ROOT_DIR" worktree remove --force "$base_tree" >/dev/null 2>&1 || true
    git -C "$ROOT_DIR" worktree add --detach "$base_tree" "$base" >/dev/null
    local measured=0
    "$base_tree/script/bench.sh" run || measured=$?
    git -C "$ROOT_DIR" worktree remove --force "$base_tree"
    if [[ "$measured" -ne 0 ]]; then
      echo "op=bench phase=compareFailed reason=baseRunFailed base=$base" >&2
      exit 1
    fi
  fi
  local before after status=0
  before="$(mktemp -t otos-bench-base)"
  after="$(mktemp -t otos-bench-head)"
  records_for "$base" > "$before"
  records_for "$head" > "$after"
  /usr/bin/python3 -I - "$threshold" "$base" "$head" "$before" "$after" <<'PY' || status=$?
import json, sys
threshold, base, head = float(sys.argv[1]), sys.argv[2], sys.argv[3]
def load(path):
    return {row["name"]: row for row in (json.loads(line) for line in open(path) if line.strip())}
before, after = load(sys.argv[4]), load(sys.argv[5])
flagged = []
print("base %s  head %s  flag above +%.1f%% instructions" % (base[:9], head[:9], threshold))
print("%-36s %14s %14s %9s %10s %10s" % ("case", "base M instr", "head M instr", "change", "base ms", "head ms"))
for name in sorted(after):
    new = after[name]
    old = before.get(name)
    if old is None:
        print("%-36s %14s %14.1f %9s %10s %10.1f  new case" % (name, "-", new["instructions"] / 1e6, "-", "-", new["medianMilliseconds"]))
        continue
    change = (new["instructions"] - old["instructions"]) / old["instructions"] * 100
    mark = "  FLAG" if change > threshold else ""
    if mark:
        flagged.append(name)
    print("%-36s %14.1f %14.1f %+8.1f%% %10.1f %10.1f%s" % (
        name, old["instructions"] / 1e6, new["instructions"] / 1e6, change,
        old["medianMilliseconds"], new["medianMilliseconds"], mark))
for name in sorted(set(before) - set(after)):
    print("%-36s  removed" % name)
if flagged:
    print("op=bench phase=flagged cases=%s" % ",".join(flagged))
    sys.exit(3)
print("op=bench phase=compared flagged=0")
PY
  rm -f "$before" "$after"
  return "$status"
}

case "${1:-}" in
  run) run ;;
  history) history "${2:-}" ;;
  compare) compare "${2:-}" ;;
  *) usage; exit 2 ;;
esac
