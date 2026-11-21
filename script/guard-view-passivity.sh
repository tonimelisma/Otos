#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard-scan.sh"
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST=("OtosKit/ContentView.swift")
is_allowlisted() { local p="$1"; [[ "$p" == "${ALLOWLIST[0]}" ]]; }
check_root() {
  local root="$1" line abs rel
  guard_scans guard-view-passivity "$root/OtosKit/Views" || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue; abs="${line%%:*}"; rel="${abs#"$root/"}"
    if ! is_allowlisted "$rel"; then echo "FAIL: ARC-011/ARC-015 view passivity violation: $line" >&2; return 1; fi
  done < <(grep -RInE 'CatalogStore|CatalogProjection|import GRDB|\bGRDB\b' "$root/OtosKit/Views" --include='*.swift' || true)
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  if check_root "$d/missing" 2>/dev/null; then echo "guard-view-passivity self-test failed (a missing scan root passed)" >&2; return 1; fi
  mkdir -p "$d/OtosKit/Views"; printf 'let store: CatalogStore\n' > "$d/OtosKit/Views/Bad.swift"
  if check_root "$d"; then echo "guard-view-passivity self-test failed" >&2; return 1; fi
  printf 'struct PlainView {}\n' > "$d/OtosKit/Views/Bad.swift"; check_root "$d"
  echo "guard-view-passivity self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
