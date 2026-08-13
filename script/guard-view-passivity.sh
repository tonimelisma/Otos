#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST=("Otos/ContentView.swift")
is_allowlisted() { local p="$1"; [[ "$p" == "${ALLOWLIST[0]}" ]]; }
check_root() {
  local root="$1" line abs rel
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue; abs="${line%%:*}"; rel="${abs#"$root/"}"
    if ! is_allowlisted "$rel"; then echo "FAIL: ARC-011/ARC-015 view passivity violation: $line" >&2; return 1; fi
  done < <(grep -RInE 'CatalogStore|CatalogProjection|import GRDB|\bGRDB\b' "$root/Otos/Views" --include='*.swift' || true)
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/Otos/Views"; printf 'let store: CatalogStore\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-view-passivity self-test failed" >&2; return 1; fi
  printf 'struct PlainView {}\n' > "$d/Otos/Views/Bad.swift"; check_root "$d"
  echo "guard-view-passivity self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
