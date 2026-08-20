#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

check_root() {
  local root="$1"
  local file="$root/Otos/Services/MediaOperationCoordinator.swift"
  local count
  count="$(grep -c 'continuation\.yield' "$file" || true)"
  if [[ "$count" != "2" ]]; then
    echo "FAIL: MediaOperationCoordinator must have exactly two continuation.yield call sites; found $count" >&2
    return 1
  fi
}

self_test() {
  local d
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/Otos/Services"
  printf '%s\n' 'continuation.yield([])' 'continuation.yield([])' > "$d/Otos/Services/MediaOperationCoordinator.swift"
  check_root "$d"
  printf '%s\n' 'continuation.yield([])' >> "$d/Otos/Services/MediaOperationCoordinator.swift"
  if check_root "$d"; then
    echo "guard-presentation-yield self-test failed" >&2
    return 1
  fi
  echo "guard-presentation-yield self-test: clean oracle"
}

case "${1:-check}" in
check) check_root "$ROOT_DIR" ;;
self-test) self_test ;;
*) echo "Usage: $0 [check|self-test]" >&2; exit 2 ;;
esac
