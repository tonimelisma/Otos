#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Each coordinator stream has one publication path: the value a new subscriber is
# opened with, and the one place that publishes changes. Presentations yield through
# `continuation` (subscribe, `publish()`); destination maps through `subscriber`
# (subscribe, `publishDestinations()`). A third yield site is a second path.
check_root() {
  local root="$1"
  local file="$root/OtosKit/Services/MediaOperationCoordinator.swift"
  local name count
  for name in continuation subscriber; do
    count="$(grep -c "${name}\\.yield" "$file" || true)"
    if [[ "$count" != "2" ]]; then
      echo "FAIL: MediaOperationCoordinator must have exactly two ${name}.yield call sites; found $count" >&2
      return 1
    fi
  done
}

self_test() {
  local d
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/OtosKit/Services"
  local file="$d/OtosKit/Services/MediaOperationCoordinator.swift"
  printf '%s\n' 'continuation.yield([])' 'continuation.yield([])' 'subscriber.yield([:])' 'subscriber.yield([:])' > "$file"
  check_root "$d"
  printf '%s\n' 'continuation.yield([])' >> "$file"
  if check_root "$d" 2>/dev/null; then
    echo "guard-presentation-yield self-test failed: a third presentation yield passed" >&2
    return 1
  fi
  printf '%s\n' 'continuation.yield([])' 'continuation.yield([])' 'subscriber.yield([:])' 'subscriber.yield([:])' 'subscriber.yield([:])' > "$file"
  if check_root "$d" 2>/dev/null; then
    echo "guard-presentation-yield self-test failed: a third destination yield passed" >&2
    return 1
  fi
  echo "guard-presentation-yield self-test: clean oracle"
}

case "${1:-check}" in
check) check_root "$ROOT_DIR" ;;
self-test) self_test ;;
*) echo "Usage: $0 [check|self-test]" >&2; exit 2 ;;
esac
