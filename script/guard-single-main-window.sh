#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
check_root() {
  local root="$1" file="$1/OtosKit/OtosApp.swift" count groups
  count="$({ grep -oE '\bWindow\s*\(' "$file" || true; } | wc -l | tr -d ' ')"
  groups="$({ grep -oE '\bWindowGroup\s*\(' "$file" || true; } | wc -l | tr -d ' ')"
  case "$count:$groups" in
    1:0) return 0 ;;
    *) echo "FAIL: ARC-014 requires one Window and zero WindowGroup" >&2; return 1 ;;
  esac
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/OtosKit"; printf 'WindowGroup("bad") {}\n' > "$d/OtosKit/OtosApp.swift"
  if check_root "$d"; then echo "guard-single-main-window self-test failed" >&2; return 1; fi
  printf 'Window("good") {}\n' > "$d/OtosKit/OtosApp.swift"; check_root "$d"
  echo "guard-single-main-window self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
