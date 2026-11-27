#!/usr/bin/env bash
set -euo pipefail
# Shared by every script that runs tests through xcodebuild (test.sh, bench.sh).

# xcodebuild's console names a failed Swift Testing test but never says why: the issue text
# lives only in the run's result bundle, and DerivedData keeps just the newest few bundles.
# Printed here, as soon as the run ends, one machine-greppable line per issue, so the
# reason a run failed survives in its log after the bundle is gone. `$1` is the log
# xcodebuild's output went to.
otos_print_test_failure_reasons() {
  local log_file="$1" bundle
  bundle="$( (grep -A1 '^Test session results, code coverage, and logs:' "$log_file" || true) | tail -n 1 | sed 's/^[[:space:]]*//')"
  if [[ "$bundle" != *.xcresult || ! -d "$bundle" ]]; then
    echo "op=test.failure phase=unreadable reason=noResultBundle"
    return
  fi
  local tests_json
  tests_json="$(mktemp)"
  if ! xcrun xcresulttool get test-results tests --path "$bundle" > "$tests_json" 2>&1; then
    echo "op=test.failure phase=unreadable reason=xcresulttoolFailed bundle=$bundle detail=$(head -c 300 "$tests_json" | tr '\n' ' ')"
    rm -f "$tests_json"
    return
  fi
  /usr/bin/python3 -I - "$tests_json" "$bundle" <<'PY'
import json
import sys

tests_path, bundle = sys.argv[1], sys.argv[2]
with open(tests_path) as handle:
    tree = json.load(handle)


def one_line(text):
    return " ".join(text.split())


printed = 0


def walk(node, test):
    global printed
    if node.get("nodeType") == "Test Case":
        test = node.get("nodeIdentifier") or node.get("name", "unknown")
    if node.get("nodeType") == "Failure Message":
        location = node.get("sourceLocation") or {}
        path = location.get("filePath", "unknown").removeprefix("/^worktree/")
        line = location.get("lineNumber", "?")
        print(f"op=test.failure test={test} at={path}:{line} message={one_line(node.get('name', ''))}")
        printed += 1
    for child in node.get("children", []):
        walk(child, test)


for root in tree.get("testNodes", []):
    walk(root, "none")
if printed == 0:
    # A failed run with no issue in its bundle (a crash, a killed host) says so rather than
    # passing for a run whose failures were read.
    print(f"op=test.failure phase=noIssueRecorded bundle={bundle}")
PY
  rm -f "$tests_json"
}

# A test host that crashes fails every test it was running with `Crash: xctest` and no
# issue of its own, so the run's log never says what crashed. The system's crash report does:
# each one written since `$2` (a file made as the run started) for a test host (`xctest`,
# `OtosTests-Runner`) is copied beside the log, which CI keeps (`logs/`), and its exception,
# the crash message the process left, and the faulting thread's top frames are printed as one
# `op=test.crash` line. The tests run on generated fixtures, so a report holds nothing
# personal. `$1` is the log xcodebuild's output went to.
otos_report_test_host_crashes() {
  local log_file="$1" since="$2" reports=() report copy
  local folder="$HOME/Library/Logs/DiagnosticReports"
  if [[ -d "$folder" ]]; then
    while IFS= read -r report; do
      reports+=("$report")
    done < <(find "$folder" -maxdepth 1 -type f \( -name 'xctest*.ips' -o -name 'OtosTests*.ips' \) -newer "$since" | sort)
  fi
  if [[ ${#reports[@]} -eq 0 ]]; then
    echo "op=test.crash phase=noReport folder=$folder"
    return
  fi
  for report in "${reports[@]}"; do
    copy="${log_file%.log}-$(basename "$report")"
    cp "$report" "$copy"
    /usr/bin/python3 -I - "$copy" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    header_line, _, body_text = handle.read().partition("\n")
try:
    body = json.loads(body_text)
except json.JSONDecodeError as error:
    print(f"op=test.crash phase=unreadable report={path} error={error}")
    sys.exit(0)


def one_line(text, limit=300):
    return " ".join(str(text).split())[:limit]


exception = body.get("exception", {})
images = body.get("usedImages", [])
threads = body.get("threads", [])
faulting = body.get("faultingThread", 0)
frames = threads[faulting].get("frames", []) if faulting < len(threads) else []


def frame_name(frame):
    index = frame.get("imageIndex")
    image = images[index].get("name", "?") if isinstance(index, int) and index < len(images) else "?"
    return f"{image}:{frame.get('symbol') or hex(frame.get('imageOffset', 0))}"


asi = body.get("asi") or {}
message = " | ".join(" ".join(lines) for lines in asi.values()) if isinstance(asi, dict) else asi
print(
    f"op=test.crash report={path} process={body.get('procName', '?')} pid={body.get('pid', '?')}"
    f" exception={exception.get('type', '?')}/{exception.get('signal', '?')}"
    f" message={one_line(message) or 'none'}"
    f" thread={faulting} frames={' < '.join(frame_name(frame) for frame in frames[:10])}"
)
PY
  done
}
