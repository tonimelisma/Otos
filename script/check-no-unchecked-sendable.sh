#!/usr/bin/env bash
# ARC-042: zero unsound Sendable escapes in app and test sources. This exists because
# the requirement was verified by the string `manual:` for its whole life and drifted
# from 0 to 14 without one failing gate.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard-scan.sh"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST=(
  # Test-only UserDefaults fixture crosses the test actor boundary by construction.
  "OtosTests/TemporaryDefaults.swift"
)

is_allowlisted() {
  local path="$1"
  for allowed in "${ALLOWLIST[@]}"; do
    [[ "$path" == "$allowed" ]] && return 0
  done
  return 1
}

check_root() {
  local root="$1"
  local hits
  guard_scans check-no-unchecked-sendable "$root/OtosKit" "$root/OtosTests" || return 1
  hits="$(grep -rnE '@unchecked Sendable|nonisolated\(unsafe\)' "$root/OtosKit" "$root/OtosTests" --include='*.swift' || true)"
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    local absolute_path="${hit%%:*}"
    local relative_path="${absolute_path#"$root/"}"
    if ! is_allowlisted "$relative_path"; then
      echo "FAIL: ARC-042 forbids unsound Sendable escape. Found:" >&2
      echo "$hit" >&2
      echo "Use Mutex (Synchronization) or an actor; an allowlisted test fixture must carry a one-line justification." >&2
      return 1
    fi
  done <<< "$hits"
}

case "${1:-check}" in
check)
  check_root "$ROOT_DIR"
  ;;
# Validates: ARC-042
self-test)
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  mkdir -p "$temp_dir/OtosKit" "$temp_dir/OtosTests"
  if check_root "$temp_dir/missing" 2>/dev/null; then
    echo "check-no-unchecked-sendable self-test failed: a missing scan root passed" >&2
    exit 1
  fi
  printf 'nonisolated(unsafe) let bad = 1\n' > "$temp_dir/OtosKit/Bad.swift"
  if check_root "$temp_dir"; then
    echo "check-no-unchecked-sendable self-test failed: seeded violation passed" >&2
    exit 1
  fi
  echo "check-no-unchecked-sendable self-test: clean oracle"
  ;;
*)
  echo "Usage: $0 [check|self-test]" >&2
  exit 2
  ;;
esac
echo "ARC-042 OK: no unsound Sendable escapes."
