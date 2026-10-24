#!/usr/bin/env bash
# Time is never a stand-in for a fact that can be known (ADR 0033).
#
# Every place that waits on time names why nothing could report the fact instead,
# with a `time:` tag on the line or in the comment directly above it:
#
#   deadline     an external system that may never answer; the limit is a product
#                decision about when the user is told, or when work resumes
#   backoff      the pause after an external failure before trying again
#   schedule     a schedule the product defines (an integrity scan, a heartbeat)
#   measurement  code that measures time itself (a stall monitor, a sampler)
#   poll         re-checking a fact nothing reports; time sets only how often
#   cadence <path>  a rate limit standing on the recorded measurement at <path>
#
# There is no allowlist. A wait without a tag, or a cadence whose measurement does not
# exist, fails the check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SWIFT_WAIT='Task\.sleep|\.sleep\((for|until|nanoseconds):|asyncAfter\(|Timer\.(scheduledTimer|publish)|Thread\.sleep|usleep\(|makeTimerSource|\.wait\(timeout:'
# A shell wait in command position: at the start of a line or after `;`, `&&`, `||`,
# `|`, `(` or `$(` — not the word inside prose or a heredoc.
SHELL_WAIT='(^[[:space:]]*|[;&|(][[:space:]]*|\$\([[:space:]]*)(sleep|timeout)[[:space:]]|read[[:space:]][^|;&]*-[a-zA-Z]*t[[:space:]]'

violations=0
report() {
  echo "op=time-guard phase=violation file=$1 line=$2 reason=$3" >&2
  violations=$((violations + 1))
}

check_file() {
  local file="$1" pattern="$2"
  local line_number tag
  while IFS=: read -r line_number _; do
    tag="$(awk -v n="$line_number" 'NR >= n - 3 && NR <= n' "$file" | grep -oE 'time: (deadline|backoff|schedule|measurement|poll|cadence [^ ]+)' | tail -n 1 || true)"
    if [[ -z "$tag" ]]; then
      report "$file" "$line_number" "untagged"
      continue
    fi
    if [[ "$tag" == "time: cadence "* ]]; then
      local evidence="${tag#time: cadence }"
      evidence="${evidence%%[),;\`]*}"
      evidence="${evidence%.}"
      [[ -f "$evidence" ]] || report "$file" "$line_number" "missingMeasurement:$evidence"
    fi
  done < <(grep -nE "$pattern" "$file" | grep -vE '^[0-9]+:[[:space:]]*(//|#)' || true)
}

while IFS= read -r file; do
  case "$file" in
    *.swift) check_file "$file" "$SWIFT_WAIT" ;;
    *.sh) check_file "$file" "$SHELL_WAIT" ;;
  esac
done < <(git ls-files Otos OtosTests script)

if (( violations > 0 )); then
  echo "op=time-guard phase=finish outcome=failed violations=$violations" >&2
  exit 1
fi
echo "op=time-guard phase=finish outcome=clean"
