#!/usr/bin/env bash
# test-without-building reuses whatever script/build.sh (build-for-testing)
# last produced in build/DerivedData; run that first, or this has nothing to
# test against.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/xcode.sh"
source "$ROOT_DIR/script/lib/run-context.sh"
source "$ROOT_DIR/script/lib/build-folder.sh"
source "$ROOT_DIR/script/lib/test-failures.sh"

otos_require_full_xcode
otos_hold_build_folder "$ROOT_DIR/build/DerivedData" test

LOG_FILE="$(otos_log_file "$ROOT_DIR" test test)"
echo "Capturing test output to $LOG_FILE"

# OTOS_SCALE_TEST gates the on-disk ~25k-asset projection scale test — it is
# materially slower than the default suite, so it stays skipped
# unless requested. xcodebuild does not forward shell environment variables to a
# UI-hosted XCTest bundle; the Otos.xcscheme's LaunchAction EnvironmentVariables
# entry substitutes `$(OTOS_SCALE_TEST)`, which only resolves when passed as a
# trailing build-setting-style argument here, not as an inherited env var.
#
# OTOS_ONLY_TESTING narrows the run to space-separated `OtosTests/<Suite>`
# identifiers (script/check.sh --only). A narrowed run is iteration feedback, not
# verification evidence.
#
# macOS ships bash 3.2, where `"${ARR[@]}"` on a zero-element array is an unbound
# -variable error under `set -u`; the argument array therefore always starts
# non-empty and only grows.
TEST_HOST_FOOTPRINT_LIMIT_MB="${OTOS_TEST_HOST_FOOTPRINT_LIMIT_MB:-2048}"

test_host_descendants() {
  local parent="$1"
  local child
  for child in $(pgrep -P "$parent" 2>/dev/null || true); do
    echo "$child"
    test_host_descendants "$child"
  done
}

physical_footprint_mb() {
  local pid="$1"
  footprint -p "$pid" 2>/dev/null | awk '
    /Footprint:/ && $0 !~ /peak/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "Footprint:") {
          number = $(i + 1)
          unit = $(i + 2)
          if (unit == "GB" || unit == "G") number *= 1024
          else if (unit == "KB" || unit == "K") number /= 1024
          printf "%.0f\n", number
          exit
        }
      }
    }
  '
}

monitored_test_pids() {
  local xcodebuild_pid="$1"
  echo "$xcodebuild_pid"
  test_host_descendants "$xcodebuild_pid"
}

monitor_test_host_footprint() {
  local xcodebuild_pid="$1"
  local monitor_file="$2"

  while kill -0 "$xcodebuild_pid" >/dev/null 2>&1; do
    local pid footprint_mb last_test host_pid
    for pid in $(monitored_test_pids "$xcodebuild_pid" | sort -u); do
      footprint_mb="$(physical_footprint_mb "$pid")"
      if [[ -n "$footprint_mb" && "$footprint_mb" -gt "$TEST_HOST_FOOTPRINT_LIMIT_MB" ]]; then
        last_test="$(grep -E 'started\.|Test Case.*started|◇ Test.*started' "$LOG_FILE" | tail -n 1 || true)"
        {
          echo "Test-host resource ceiling exceeded."
          echo "pid=$pid footprint_mb=$footprint_mb limit_mb=$TEST_HOST_FOOTPRINT_LIMIT_MB"
          echo "last_test=${last_test:-unknown}"
        } > "$monitor_file"
        for host_pid in $(monitored_test_pids "$xcodebuild_pid" | sort -u); do
          [[ "$host_pid" == "$xcodebuild_pid" ]] && continue
          kill "$host_pid" >/dev/null 2>&1 || true
        done
        kill "$xcodebuild_pid" >/dev/null 2>&1 || true
        return 1
      fi
    done
    # time: measurement — samples the test host's memory footprint
    sleep 2
  done
  return 0
}

run_tests_with_footprint_guard() {
  local monitor_file
  monitor_file="$(mktemp)"

  local args=(
    -project "$ROOT_DIR/Otos.xcodeproj"
    -scheme Otos
    -configuration Debug
    -destination "platform=macOS"
    -derivedDataPath "$ROOT_DIR/build/DerivedData"
    -enableCodeCoverage NO
    test-without-building
  )
  local identifier
  for identifier in ${OTOS_ONLY_TESTING:-}; do
    args+=("-only-testing:$identifier")
  done
  if [[ -n "${OTOS_SCALE_TEST:-}" ]]; then
    echo "OTOS_SCALE_TEST set: including the on-disk projection scale test."
    args+=("OTOS_SCALE_TEST=$OTOS_SCALE_TEST")
  fi
  /usr/bin/xcodebuild "${args[@]}" > "$LOG_FILE" 2>&1 &
  local xcodebuild_pid="$!"
  monitor_test_host_footprint "$xcodebuild_pid" "$monitor_file" &
  local monitor_pid="$!"
  local test_status=0
  wait "$xcodebuild_pid" || test_status=$?
  kill "$monitor_pid" >/dev/null 2>&1 || true
  wait "$monitor_pid" >/dev/null 2>&1 || true
  cat "$LOG_FILE"
  if [[ "$test_status" -ne 0 ]]; then
    otos_print_test_failure_reasons "$LOG_FILE"
  fi
  # `-only-testing:` matches by suite (type) name, not by file name, and a name
  # that matches nothing runs nothing and succeeds. A narrowed suite that ran no
  # test case is a wrong name, never a pass. Only a case that passed or failed ran: a
  # gated suite reports every case `skipped on`, and a skip executed nothing.
  for identifier in ${OTOS_ONLY_TESTING:-}; do
    local suite="${identifier#OtosTests/}"
    if ! grep -qE "Test case '${suite}/[^']*' (passed|failed) on " "$LOG_FILE"; then
      echo "op=test.scope phase=noTestsRan suite=$suite — no test of a suite by that name passed or failed: the name matches no suite (suites are type names, not file names), or every case in it was skipped" >&2
      test_status=1
    fi
  done
  if [[ -s "$monitor_file" ]]; then
    cat "$monitor_file" >&2
    test_status=1
  fi
  rm -f "$monitor_file"
  return "$test_status"
}

run_tests_with_footprint_guard
