#!/usr/bin/env bash
# Benchmarks (ADR 0043).
#
#   script/bench.sh run             Build, run the benchmark suite (OtosTests/BenchmarkTests),
#                                   print the results, and record them on HEAD when the tree
#                                   is clean.
#   script/bench.sh history [case]  Every recorded result, newest first, with the change in
#                                   instructions from the previous record on the same machine.
#   script/bench.sh compare [base]  HEAD's runs against base's (default: the merge base with
#                                   origin/main), measuring base first when it has no record.
#                                   Exits 3 when a case retired more than 2% more instructions
#                                   (OTOS_BENCH_FLAG_PERCENT) beyond every run's range, in at
#                                   least two runs a side, measuring a side again when it has
#                                   one: the owner decides whether it merges.
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
  source "$ROOT_DIR/script/lib/build-folder.sh"
  otos_require_full_xcode
  otos_build_settings "$ROOT_DIR"
  otos_hold_build_folder "$ROOT_DIR/build/DerivedData" bench
  # What this run measures, read before the build: a pull during the run must not
  # record these results on the commit it moved to.
  local commit tree clean=1
  commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  tree="$(otos_tree_identity "$ROOT_DIR")"
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || clean=0
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
    build-for-testing "${OTOS_BUILD_SETTINGS[@]}" > "$log_file" 2>&1 || {
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
    -enableCodeCoverage NO \
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

  if [[ "$(otos_tree_identity "$ROOT_DIR")" != "$tree" ]]; then
    echo "op=bench phase=notRecorded reason=treeChangedDuringRun commit=$commit"
    return
  fi
  if [[ "$clean" == 0 ]]; then
    echo "op=bench phase=notRecorded reason=uncommittedChanges"
    return
  fi
  local note
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
  append_note "$commit" "$note"
  echo "op=bench phase=recorded commit=$commit ref=$NOTES_REF"
}

# Appends a run's records to the commit's note without losing another session's.
# `git notes append` reads the notes ref, writes a commit on it and moves the ref with no
# check that it is unchanged, so two sessions recording at once each build on the same
# parent and the later one drops the earlier's records. The append is built on a ref of
# this process's own and the shared ref moves only if it still points where that append
# began; a race starts it again on the new tip.
append_note() {
  local commit="$1" note="$2"
  local scratch="refs/notes/bench-append-$$"
  local none="0000000000000000000000000000000000000000"
  local attempt old new
  for attempt in $(seq 1 20); do
    old="$(git -C "$ROOT_DIR" rev-parse -q --verify "$NOTES_REF" || true)"
    if [[ -n "$old" ]]; then
      git -C "$ROOT_DIR" update-ref "$scratch" "$old"
    else
      git -C "$ROOT_DIR" update-ref -d "$scratch" 2>/dev/null || true
    fi
    git -C "$ROOT_DIR" notes --ref="$scratch" append -m "$note" "$commit"
    new="$(git -C "$ROOT_DIR" rev-parse "$scratch")"
    if git -C "$ROOT_DIR" update-ref "$NOTES_REF" "$new" "${old:-$none}" 2>/dev/null; then
      git -C "$ROOT_DIR" update-ref -d "$scratch"
      return 0
    fi
    echo "op=bench phase=recordRaced attempt=$attempt commit=$commit"
  done
  git -C "$ROOT_DIR" update-ref -d "$scratch"
  echo "op=bench phase=failed reason=recordRaced commit=$commit" >&2
  exit 1
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
# Every run of this commit on this machine: each run is one test process, and the count
# can drift between processes by more than it moves inside one (ADR 0043).
for line in shown.stdout.splitlines():
    if line.startswith("{"):
        row = json.loads(line)
        if row["machine"] == machine and row["configuration"] == "Debug":
            print(json.dumps(row, sort_keys=True))
PY
}

# Measures base again in its own detached checkout, which records it like any run.
measure_base() {
  local base="$1"
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
}

# Sets each side's runs against the other's. Exits 3 when a case rose beyond every run's
# range, and 4 when a case would flag but one side has fewer than two runs, so the caller
# measures it again before deciding (with `final`, such a case flags).
judge() {
  local threshold="$1" base="$2" head="$3" before="$4" after="$5" final="$6"
  /usr/bin/python3 -I - "$threshold" "$base" "$head" "$before" "$after" "$final" <<'PY'
import json, statistics, sys
threshold, base, head, final = float(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[6] == "1"
def load(path):
    runs = {}
    for line in open(path):
        if line.strip():
            row = json.loads(line)
            runs.setdefault(row["name"], []).append(row)
    return runs
before, after = load(sys.argv[4]), load(sys.argv[5])
flagged, unconfirmed = [], []
print("base %s  head %s  flag above +%.1f%% instructions, beyond every run's range" % (base[:9], head[:9], threshold))
print("%-36s %14s %14s %9s %5s %10s %10s" % ("case", "base M instr", "head M instr", "change", "runs", "base ms", "head ms"))
for name in sorted(after):
    new_runs = after[name]
    old_runs = before.get(name)
    new = statistics.median(run["instructions"] for run in new_runs)
    new_ms = statistics.median(run["medianMilliseconds"] for run in new_runs)
    if not old_runs:
        print("%-36s %14s %14.1f %9s %5s %10s %10.1f  new case" % (name, "-", new / 1e6, "-", "-", "-", new_ms))
        continue
    old = statistics.median(run["instructions"] for run in old_runs)
    old_ms = statistics.median(run["medianMilliseconds"] for run in old_runs)
    change = (new - old) / old * 100
    # A rise counts only when it is beyond the noise of every run on both sides: a run's
    # spread is its samples' range over its median, and the count also drifts from one
    # test process to the next, which no single run's spread shows. So no base sample of
    # any run may reach the lowest head sample of any run, and each side needs two runs.
    base_highest = max(run["instructions"] * (1 + run.get("instructionSpread", 0)) for run in old_runs)
    head_lowest = min(run["instructions"] * (1 - run.get("instructionSpread", 0)) for run in new_runs)
    runs = "%d/%d" % (len(old_runs), len(new_runs))
    if change > threshold and head_lowest > base_highest:
        if final or (len(old_runs) >= 2 and len(new_runs) >= 2):
            mark = "  FLAG"
            flagged.append(name)
        else:
            mark = "  to confirm"
            unconfirmed.append(name)
    elif change > threshold:
        mark = "  within noise"
    else:
        mark = ""
    print("%-36s %14.1f %14.1f %+8.1f%% %5s %10.1f %10.1f%s" % (
        name, old / 1e6, new / 1e6, change, runs, old_ms, new_ms, mark))
for name in sorted(set(before) - set(after)):
    print("%-36s  removed" % name)
if unconfirmed:
    print("op=bench phase=confirm cases=%s" % ",".join(unconfirmed))
    sys.exit(4)
if flagged:
    print("op=bench phase=flagged cases=%s" % ",".join(flagged))
    sys.exit(3)
print("op=bench phase=compared flagged=0")
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
    measure_base "$base"
  fi
  local before after status=0 final=0
  before="$(mktemp -t otos-bench-base)"
  after="$(mktemp -t otos-bench-head)"
  while true; do
    records_for "$base" > "$before"
    records_for "$head" > "$after"
    status=0
    judge "$threshold" "$base" "$head" "$before" "$after" "$final" || status=$?
    [[ "$status" -eq 4 && "$final" -eq 0 ]] || break
    # A case would flag on one side's single run: each side with one run is measured
    # again, in a new test process, and the case judged once more.
    final=1
    if [[ "$(runs_of "$after")" -lt 2 ]]; then
      echo "op=bench phase=confirm side=head commit=$head"
      if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
        echo "op=bench phase=compareFailed reason=headTreeDirty commit=$head" >&2
        exit 1
      fi
      run
    fi
    if [[ "$(runs_of "$before")" -lt 2 ]]; then
      echo "op=bench phase=confirm side=base commit=$base"
      measure_base "$base"
    fi
  done
  rm -f "$before" "$after"
  return "$status"
}

# The fewest runs any case in a record file has.
runs_of() {
  /usr/bin/python3 -I - "$1" <<'PY'
import collections, json, sys
counts = collections.Counter(json.loads(line)["name"] for line in open(sys.argv[1]) if line.strip())
print(min(counts.values()) if counts else 0)
PY
}

case "${1:-}" in
  run) run ;;
  history) history "${2:-}" ;;
  compare) compare "${2:-}" ;;
  *) usage; exit 2 ;;
esac
