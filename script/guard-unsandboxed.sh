#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard-scan.sh"
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
check_root() {
  local root="$1"
  guard_scans guard-unsandboxed "$root/Otos.xcodeproj" "$root/OtosKit" || return 1
  if grep -RInE 'com\.apple\.security\.app-sandbox|CODE_SIGN_ENTITLEMENTS' "$root/Otos.xcodeproj" "$root/OtosKit" --include='project.pbxproj' --include='*.swift' --include='*.entitlements' 2>/dev/null; then
    echo "FAIL: ARC-002 forbids sandbox entitlements" >&2; return 1
  fi
  if grep -RInE 'startAccessingSecurityScopedResource|bookmarkData\(options:|\.withSecurityScope' "$root/OtosKit" --include='*.swift'; then
    echo "FAIL: ARC-002 forbids security-scoped access" >&2; return 1
  fi
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  if check_root "$d/missing" 2>/dev/null; then echo "guard-unsandboxed self-test failed (a missing scan root passed)" >&2; return 1; fi
  mkdir -p "$d/Otos.xcodeproj" "$d/OtosKit"
  printf 'CODE_SIGN_ENTITLEMENTS = bad.entitlements;\n' > "$d/Otos.xcodeproj/project.pbxproj"
  if check_root "$d"; then echo "guard-unsandboxed self-test failed" >&2; return 1; fi
  rm "$d/Otos.xcodeproj/project.pbxproj"
  printf 'url.startAccessingSecurityScopedResource()\n' > "$d/OtosKit/Bad.swift"
  if check_root "$d"; then echo "guard-unsandboxed self-test failed" >&2; return 1; fi
  echo "guard-unsandboxed self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
