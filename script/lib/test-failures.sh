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
