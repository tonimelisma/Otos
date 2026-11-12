#!/usr/bin/env bash
# Benchmarks (ADR 0043).
#
#   script/bench.sh run             Build, run the benchmark suite (OtosTests/BenchmarkTests)
#                                   in OTOS_BENCH_PROCESSES fresh test processes (default 3),
#                                   print the results, and record them on HEAD when the tree
#                                   is clean.
#   script/bench.sh nightly         Measure origin/main's newest commit in a detached checkout
#                                   and set it against the baseline, the last commit that
#                                   measured clean. Clean moves the baseline; a flagged case
#                                   leaves it and stays flagged until a later night is clean
#                                   or the owner accepts it. launchd runs it every night.
#   script/bench.sh status          One line: the nightly verdict, and how far origin/main is
#                                   past the baseline. script/check.sh prints it.
#   script/bench.sh accept          Move the baseline to the flagged commit. Only on the
#                                   owner's word: a regression may be a feature's price.
#   script/bench.sh schedule        Install the nightly launchd agent for this checkout.
#   script/bench.sh history [case]  Every recorded result, newest first, with the change in
#                                   instructions from the previous record on the same machine.
#   script/bench.sh compare [base]  HEAD's processes against base's (default: the merge base
#                                   with origin/main), measuring base first when this harness
#                                   has not. Exits 3 when a case retired more instructions
#                                   than both 2% (OTOS_BENCH_FLAG_PERCENT) and the case's own
#                                   process-to-process noise allow, beyond every process's
#                                   range. For bisecting a flagged night by hand.
#
# Results are recorded as git notes on the commit they measured (refs/notes/benchmarks),
# one JSON object per case and test process. Instructions retired is the number to compare:
# it barely moves under machine load, which wall time does several-fold. A run on a tree
# with uncommitted changes prints its results but records nothing, because no commit is
# what it measured.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTES_REF="refs/notes/benchmarks"
# What a record's numbers mean. compare sets only records of this harness against each
# other; older ones stay as history. Raise it with any change to what a run counts.
#   2: one hash seed in every process (SWIFT_DETERMINISTIC_HASHING), several processes a run.
HARNESS=2
PROCESSES="${OTOS_BENCH_PROCESSES:-3}"
# How many of the newest measured commits a case's process-to-process noise is read from.
NOISE_COMMITS=10
# The nightly's state, shared by every worktree of the clone: the baseline is a ref, the
# verdict a one-line file beside it.
COMMON_DIR="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)"
BASELINE_REF="refs/bench/baseline"
VERDICT_FILE="$COMMON_DIR/otos-bench-verdict"
# How far origin/main may run past the baseline before status asks for a run by hand: the
# nightly did not run (the Mac was off for days, or the agent is not installed).
STALE_COMMITS=20

usage() {
  sed -n '4,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# One row per case: the median over processes, the range across processes, and the widest
# range inside any one process.
print_results() {
  /usr/bin/python3 -I - "$1" <<'PY'
import collections, json, statistics, sys
runs = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if line.strip():
        row = json.loads(line)
        runs[row["name"]].append(row)
print(f"{'case':<36} {'M instructions':>15} {'across':>7} {'within':>7} {'median ms':>10}")
for name, rows in runs.items():
    counts = [row["instructions"] for row in rows]
    print(f"{name:<36} {statistics.median(counts) / 1e6:>15.1f} "
          f"{(max(counts) - min(counts)) / min(counts) * 100:>6.1f}% "
          f"{max(row['instructionSpread'] for row in rows) * 100:>6.1f}% "
          f"{statistics.median(row['medianMilliseconds'] for row in rows):>10.1f}")
PY
}

# Measures one checkout with this harness: this one by default, or base's detached
# checkout for `compare`.
run() {
  local tree="${1:-$ROOT_DIR}"
  source "$ROOT_DIR/script/lib/xcode.sh"
  source "$ROOT_DIR/script/lib/run-context.sh"
  source "$ROOT_DIR/script/lib/build-folder.sh"
  otos_require_full_xcode
  otos_build_settings "$tree"
  otos_hold_build_folder "$tree/build/DerivedData" bench
  # What this run measures, read before the build: a pull during the run must not
  # record these results on the commit it moved to.
  local commit identity clean=1
  commit="$(git -C "$tree" rev-parse HEAD)"
  identity="$(otos_tree_identity "$tree")"
  [[ -z "$(git -C "$tree" status --porcelain)" ]] || clean=0
  local log_file results measured
  log_file="$(otos_log_file "$tree" bench bench)"
  results="$tree/build/benchmarks/results.ndjson"
  measured="$tree/build/benchmarks/processes.ndjson"
  mkdir -p "$tree/build/benchmarks"
  rm -f "$measured"
  echo "op=bench phase=build commit=$commit log=$log_file"
  /usr/bin/xcodebuild \
    -project "$tree/Otos.xcodeproj" \
    -scheme Otos \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$tree/build/DerivedData" \
    build-for-testing "${OTOS_BUILD_SETTINGS[@]}" > "$log_file" 2>&1 || {
    echo "op=bench phase=failed reason=build log=$log_file" >&2
    exit 1
  }
  # A process's count differs from the next process's by more than its own samples vary
  # (ADR 0043), so a run's evidence is several processes, each measured on its own.
  local process
  for process in $(seq 1 "$PROCESSES"); do
    echo "op=bench phase=run process=$process/$PROCESSES"
    rm -f "$results"
    # The scheme substitutes $(OTOS_BENCHMARK) into the test environment; xcodebuild
    # resolves it only from a trailing build-setting argument, not an inherited variable.
    # A TEST_RUNNER_ variable reaches the test process without its prefix: one hash seed
    # for every process, so a Set's or Dictionary's layout is not drawn per process.
    TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1 /usr/bin/xcodebuild \
      -project "$tree/Otos.xcodeproj" \
      -scheme Otos \
      -configuration Debug \
      -destination "platform=macOS" \
      -derivedDataPath "$tree/build/DerivedData" \
      -enableCodeCoverage NO \
      test-without-building \
      -only-testing:OtosTests/BenchmarkTests \
      OTOS_BENCHMARK=1 >> "$log_file" 2>&1 || {
      echo "op=bench phase=failed reason=test process=$process log=$log_file" >&2
      exit 1
    }
    if [[ ! -s "$results" ]]; then
      echo "op=bench phase=failed reason=noResults process=$process log=$log_file" >&2
      exit 1
    fi
    /usr/bin/python3 -I - "$results" "$process" >> "$measured" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    if line.strip():
        row = json.loads(line)
        row["process"] = int(sys.argv[2])
        print(json.dumps(row, sort_keys=True))
PY
  done
  print_results "$measured"

  if [[ "$(otos_tree_identity "$tree")" != "$identity" ]]; then
    echo "op=bench phase=notRecorded reason=treeChangedDuringRun commit=$commit"
    return
  fi
  if [[ "$clean" == 0 ]]; then
    echo "op=bench phase=notRecorded reason=uncommittedChanges"
    return
  fi
  local note
  note="$(/usr/bin/python3 -I - "$measured" "$commit" "$HARNESS" \
    "$(/usr/sbin/sysctl -n hw.model)" \
    "$(/usr/bin/sw_vers -productVersion)" \
    "$(/usr/bin/xcodebuild -version | head -n 1)" \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys
path, commit, harness, machine, macos, xcode, measured = sys.argv[1:8]
for line in open(path):
    if line.strip():
        row = json.loads(line)
        row.update(commit=commit, harness=int(harness), machine=machine, macOS=macos,
                   xcode=xcode, configuration="Debug", measuredAt=measured)
        print(json.dumps(row, sort_keys=True))
PY
)"
  append_note "$commit" "$note"
  echo "op=bench phase=recorded commit=$commit processes=$PROCESSES ref=$NOTES_REF"
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
rows.sort(key=lambda row: (row["measuredAt"], row.get("process", 0)))
previous = {}
lines = []
for row in rows:
    # Counts compare only within one harness on one machine.
    key = (row["name"], row["machine"], row.get("harness", 1))
    before = previous.get(key)
    change = "" if before is None else "%+.1f%%" % ((row["instructions"] - before) / before * 100)
    previous[key] = row["instructions"]
    lines.append("%s  %s  h%d  %-36s %12.1fM %8s %9.1f ms  %s" % (
        row["measuredAt"][:10], row["commit"][:9], row.get("harness", 1), row["name"],
        row["instructions"] / 1e6, change, row["medianMilliseconds"], row["machine"]))
print("\n".join(reversed(lines)) if lines else "No benchmark results recorded.")
PY
}

# This harness's records on this machine, as JSON lines: one commit's, or with no commit
# every commit's. Each record is one case in one test process.
records() {
  /usr/bin/python3 -I - "$ROOT_DIR" "$NOTES_REF" "$(/usr/sbin/sysctl -n hw.model)" "$HARNESS" "${1:-}" <<'PY'
import json, subprocess, sys
root, ref, machine, harness, wanted = sys.argv[1:6]
def git(*args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True).stdout
commits = [wanted] if wanted else [line.split()[1] for line in git("notes", f"--ref={ref}", "list").splitlines()]
for commit in commits:
    for line in git("notes", f"--ref={ref}", "show", commit).splitlines():
        if line.startswith("{"):
            row = json.loads(line)
            if (row["machine"] == machine and row["configuration"] == "Debug"
                    and row.get("harness") == int(harness)):
                print(json.dumps(row, sort_keys=True))
PY
}

# Measures a commit in its own detached checkout, with this harness, which records it like
# any run.
measure_commit() {
  local commit="$1" checkout="$2"
  echo "op=bench phase=measureCommit commit=$commit tree=$checkout"
  git -C "$ROOT_DIR" worktree remove --force "$checkout" >/dev/null 2>&1 || true
  git -C "$ROOT_DIR" worktree add --quiet --detach "$checkout" "$commit"
  local measured=0
  (run "$checkout") || measured=$?
  git -C "$ROOT_DIR" worktree remove --force "$checkout"
  return "$measured"
}

measure_base() {
  measure_commit "$1" "$ROOT_DIR/build/bench-base" || {
    echo "op=bench phase=compareFailed reason=baseRunFailed base=$1" >&2
    exit 1
  }
}

# Sets head's processes against base's. A case is flagged when its median rose by more than
# the threshold and more than the case's own noise, and the rise is beyond every process's
# range. Exits 3 when a case is flagged.
judge() {
  local threshold="$1" base="$2" head="$3" before="$4" after="$5" every="$6"
  /usr/bin/python3 -I - "$threshold" "$base" "$head" "$before" "$after" "$every" "$NOISE_COMMITS" <<'PY'
import collections, json, statistics, sys
threshold, base, head = float(sys.argv[1]), sys.argv[2], sys.argv[3]
noise_commits = int(sys.argv[7])
def load(path):
    rows = []
    for line in open(path):
        if line.strip():
            rows.append(json.loads(line))
    return rows
def by_case(rows):
    runs = collections.defaultdict(list)
    for row in rows:
        runs[row["name"]].append(row)
    return runs
before, after = by_case(load(sys.argv[4])), by_case(load(sys.argv[5]))
# A case's noise: the widest range its processes spanned on any one commit, over the newest
# measured commits. One commit is one tree, so whatever its processes disagree on is noise.
newest = sorted({(row["measuredAt"], row["commit"]) for row in load(sys.argv[6])}, reverse=True)
recent = []
for _, commit in newest:
    if commit not in recent:
        recent.append(commit)
recent = set(recent[:noise_commits])
counts = collections.defaultdict(list)
for row in load(sys.argv[6]):
    if row["commit"] in recent:
        counts[(row["name"], row["commit"])].append(row["instructions"])
noise = collections.defaultdict(float)
for (name, _), values in counts.items():
    if len(values) >= 2:
        noise[name] = max(noise[name], (max(values) - min(values)) / min(values) * 100)
flagged = []
print("base %s  head %s  flag above +%.1f%% or the case's noise, beyond every process's range" % (
    base[:9], head[:9], threshold))
print("%-36s %14s %14s %9s %7s %5s %10s %10s" % (
    "case", "base M instr", "head M instr", "change", "noise", "procs", "base ms", "head ms"))
for name in sorted(after):
    new_runs = after[name]
    new = statistics.median(run["instructions"] for run in new_runs)
    new_ms = statistics.median(run["medianMilliseconds"] for run in new_runs)
    old_runs = before.get(name)
    if not old_runs:
        print("%-36s %14s %14.1f %9s %7s %5s %10s %10.1f  new case" % (
            name, "-", new / 1e6, "-", "-", "-", "-", new_ms))
        continue
    old = statistics.median(run["instructions"] for run in old_runs)
    old_ms = statistics.median(run["medianMilliseconds"] for run in old_runs)
    change = (new - old) / old * 100
    # Beyond every process's range: no base sample of any process reaches the lowest head
    # sample of any process (a process's samples span its median × (1 ± spread)).
    base_highest = max(run["instructions"] * (1 + run["instructionSpread"]) for run in old_runs)
    head_lowest = min(run["instructions"] * (1 - run["instructionSpread"]) for run in new_runs)
    bar = max(threshold, noise[name])
    if change > bar and head_lowest > base_highest:
        mark = "  FLAG"
        flagged.append(name)
    elif change > threshold:
        mark = "  within noise"
    else:
        mark = ""
    print("%-36s %14.1f %14.1f %+8.1f%% %6.1f%% %5s %10.1f %10.1f%s" % (
        name, old / 1e6, new / 1e6, change, noise[name], "%d/%d" % (len(old_runs), len(new_runs)),
        old_ms, new_ms, mark))
for name in sorted(set(before) - set(after)):
    print("%-36s  removed" % name)
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
  if [[ -z "$(records "$head")" ]]; then
    echo "op=bench phase=compareFailed reason=headNotRecorded commit=$head harness=$HARNESS (run script/bench.sh run on a clean tree first)" >&2
    exit 1
  fi
  if [[ "$base" == "$head" ]]; then
    echo "op=bench phase=compareSkipped reason=headIsBase commit=$head"
    return
  fi
  if [[ -z "$(records "$base")" ]]; then
    if ! git -C "$ROOT_DIR" cat-file -e "$base:OtosTests/BenchmarkTests.swift" 2>/dev/null; then
      echo "op=bench phase=compareSkipped reason=baseHasNoBenchmarks base=$base"
      return
    fi
    measure_base "$base"
  fi
  judge_pair "$threshold" "$base" "$head"
}

# The judged pair's records, set against each other; the judge's own exit status.
judge_pair() {
  local threshold="$1" base="$2" head="$3"
  local before after every status=0
  before="$(mktemp -t otos-bench-base)"
  after="$(mktemp -t otos-bench-head)"
  every="$(mktemp -t otos-bench-every)"
  records "$base" > "$before"
  records "$head" > "$after"
  records > "$every"
  judge "$threshold" "$base" "$head" "$before" "$after" "$every" || status=$?
  rm -f "$before" "$after" "$every"
  return "$status"
}

# origin/main as this clone last fetched it: every merge fetches it, and the nightly reads
# no network, so a network that hangs never hangs the night.
nightly() {
  local head baseline threshold output status=0
  threshold="${OTOS_BENCH_FLAG_PERCENT:-2}"
  head="$(git -C "$ROOT_DIR" rev-parse origin/main)"
  baseline="$(git -C "$ROOT_DIR" rev-parse -q --verify "$BASELINE_REF" || true)"
  echo "op=bench.nightly phase=start head=$head baseline=${baseline:-none}"
  if [[ "$head" == "$baseline" ]]; then
    echo "op=bench.nightly phase=skipped reason=headIsBaseline head=$head"
    return
  fi
  if [[ -z "$(records "$head")" ]]; then
    measure_commit "$head" "$ROOT_DIR/build/bench-nightly" || {
      echo "op=bench.nightly phase=failed reason=headRunFailed head=$head" >&2
      exit 1
    }
  fi
  if [[ -z "$baseline" ]]; then
    git -C "$ROOT_DIR" update-ref "$BASELINE_REF" "$head"
    echo "clean baseline=$head" > "$VERDICT_FILE"
    echo "op=bench.nightly phase=baselined head=$head"
    return
  fi
  output="$(judge_pair "$threshold" "$baseline" "$head")" || status=$?
  printf '%s\n' "$output"
  case "$status" in
    0)
      git -C "$ROOT_DIR" update-ref "$BASELINE_REF" "$head"
      echo "clean baseline=$head" > "$VERDICT_FILE"
      echo "op=bench.nightly phase=clean baseline=$head"
      ;;
    3)
      local cases
      cases="$(printf '%s\n' "$output" | sed -n 's/^op=bench phase=flagged cases=//p')"
      echo "flagged baseline=$baseline head=$head cases=$cases" > "$VERDICT_FILE"
      echo "op=bench.nightly phase=flagged baseline=$baseline head=$head cases=$cases"
      ;;
    *)
      echo "op=bench.nightly phase=failed reason=judge status=$status" >&2
      exit 1
      ;;
  esac
}

status() {
  local baseline verdict behind
  baseline="$(git -C "$ROOT_DIR" rev-parse -q --verify "$BASELINE_REF" || true)"
  if [[ -z "$baseline" ]]; then
    echo "op=bench.status verdict=none note=\"no night has run; script/bench.sh schedule installs the nightly\""
    return
  fi
  verdict="$(cat "$VERDICT_FILE" 2>/dev/null || echo unknown)"
  behind="$(git -C "$ROOT_DIR" rev-list --count "$baseline..origin/main")"
  case "$verdict" in
    flagged*)
      echo "op=bench.status verdict=$verdict behind=$behind action=\"fix the flagged cases first, or the owner accepts them (script/bench.sh accept)\""
      ;;
    *)
      if (( behind >= STALE_COMMITS )); then
        echo "op=bench.status verdict=stale baseline=$baseline behind=$behind action=\"run script/bench.sh nightly in the background\""
      else
        echo "op=bench.status verdict=clean baseline=$baseline behind=$behind"
      fi
      ;;
  esac
}

accept() {
  local verdict head
  verdict="$(cat "$VERDICT_FILE" 2>/dev/null || true)"
  head="$(printf '%s\n' "$verdict" | sed -n 's/^flagged .*head=\([0-9a-f]*\).*/\1/p')"
  if [[ -z "$head" ]]; then
    echo "op=bench.accept phase=refused reason=nothingFlagged verdict=\"${verdict:-none}\"" >&2
    exit 1
  fi
  git -C "$ROOT_DIR" update-ref "$BASELINE_REF" "$head"
  echo "clean baseline=$head accepted=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VERDICT_FILE"
  echo "op=bench.accept phase=accepted baseline=$head"
}

# A per-user launchd agent: 03:00 every night, and on wake when the Mac slept through it.
schedule() {
  local label="net.melisma.Otos.bench-nightly"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$ROOT_DIR/logs"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$ROOT_DIR/script/bench.sh</string><string>nightly</string></array>
  <key>WorkingDirectory</key><string>$ROOT_DIR</string>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$ROOT_DIR/logs/bench-nightly.log</string>
  <key>StandardErrorPath</key><string>$ROOT_DIR/logs/bench-nightly.log</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  echo "op=bench.schedule phase=installed label=$label plist=$plist log=$ROOT_DIR/logs/bench-nightly.log"
}

case "${1:-}" in
  run) run ;;
  history) history "${2:-}" ;;
  compare) compare "${2:-}" ;;
  nightly) nightly ;;
  status) status ;;
  accept) accept ;;
  schedule) schedule ;;
  *) usage; exit 2 ;;
esac
