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
# The ceiling catches runaway growth, not the suite's own peak: under full parallel load the
# host measured 2.85-2.9 GB for about 15 s and fell back to 1.7 GB, with nothing leaked
# (docs/research/2026-11-19-test-host-peak-under-parallel-load.md). It sits about 40% above
# that peak, as 2,048 MB once sat above the 1.4 GB measured on 2026-11-15.
TEST_HOST_FOOTPRINT_LIMIT_MB="${OTOS_TEST_HOST_FOOTPRINT_LIMIT_MB:-4096}"

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
  local pids_file="$3"

  while kill -0 "$xcodebuild_pid" >/dev/null 2>&1; do
    local pid footprint_mb last_test host_pid
    for pid in $(monitored_test_pids "$xcodebuild_pid" | sort -u); do
      echo "$pid" >> "$pids_file"
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

# Every test case's folder is `OtosTests-<pid>-<uuid>` in the per-user temporary folder, and
# the test process removes its own, at each test's end and again at exit (OtosTests/
# TestScope.swift). A folder of this run's test processes that is still there once they
# have ended is a leak: it fails the run, and is reported by count and size.
fail_on_leaked_test_folders() {
  local pids_file="$1"
  local temp leaked=0 kilobytes=0 entry name pid size
  temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
  for entry in "$temp"OtosTests-*; do
    [[ -d "$entry" ]] || continue
    name="${entry##*/}"
    pid="${name#OtosTests-}"
    pid="${pid%%-*}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    grep -qx "$pid" "$pids_file" || continue
    kill -0 "$pid" >/dev/null 2>&1 && continue
    size="$(/usr/bin/du -sk "$entry" | cut -f1)"
    leaked=$((leaked + 1))
    kilobytes=$((kilobytes + size))
  done
  if (( leaked > 0 )); then
    echo "op=test.tempLeak phase=failed folders=$leaked kilobytes=$kilobytes — a test process left its OtosTests-<pid>-* folders behind (TestTemporaryFolders removes them at exit; a host that was killed never reaches it)" >&2
    return 1
  fi
  echo "op=test.tempLeak phase=clean processes=$(sort -u "$pids_file" | wc -l | tr -d ' ')"
}

run_tests_with_footprint_guard() {
  local monitor_file pids_file
  monitor_file="$(mktemp)"
  pids_file="$(mktemp)"

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
  # OTOS_TEXT_READING_LIVE=1 includes the readings by the system's own text model
  # (SearchTextLiveReadingTests), whose cold first load can take many minutes.
  if [[ -n "${OTOS_TEXT_READING_LIVE:-}" ]]; then
    echo "OTOS_TEXT_READING_LIVE set: including the live text readings."
    args+=("OTOS_TEXT_READING_LIVE=$OTOS_TEXT_READING_LIVE")
  fi
  /usr/bin/xcodebuild "${args[@]}" > "$LOG_FILE" 2>&1 &
  local xcodebuild_pid="$!"
  monitor_test_host_footprint "$xcodebuild_pid" "$monitor_file" "$pids_file" &
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
  # test case is a wrong name, never a pass. Only a case that passed, failed or recorded
  # an expected failure (a `withKnownIssue` that held) ran: a gated suite reports every
  # case `skipped on`, and a skip executed nothing.
  for identifier in ${OTOS_ONLY_TESTING:-}; do
    local suite="${identifier#OtosTests/}"
    if ! grep -qE "Test case '${suite}/[^']*' (passed|failed|recorded an expected failure) on " "$LOG_FILE"; then
      echo "op=test.scope phase=noTestsRan suite=$suite — no test of a suite by that name passed or failed: the name matches no suite (suites are type names, not file names), or every case in it was skipped" >&2
      test_status=1
    fi
  done
  if [[ -s "$monitor_file" ]]; then
    cat "$monitor_file" >&2
    test_status=1
  fi
  fail_on_leaked_test_folders "$pids_file" || test_status=1
  rm -f "$monitor_file" "$pids_file"
  return "$test_status"
}

run_tests_with_footprint_guard
