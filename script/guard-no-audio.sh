#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard-scan.sh"
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
check_root() {
  local root="$1"
  guard_scans guard-no-audio "$root/OtosKit" || return 1
  if grep -RInE 'AVAudio|UTType\.audio|kUTTypeAudio|AVAudioSession|audioPlayer' "$root/OtosKit" --include='*.swift'; then
    echo "FAIL: MED-004 forbids audio workflows" >&2; return 1
  fi
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  if check_root "$d/missing" 2>/dev/null; then echo "guard-no-audio self-test failed (a missing scan root passed)" >&2; return 1; fi
  mkdir -p "$d/OtosKit"; printf 'let p = AVAudioPlayer()\n' > "$d/OtosKit/Bad.swift"
  if check_root "$d"; then echo "guard-no-audio self-test failed" >&2; return 1; fi
  : > "$d/OtosKit/Bad.swift"; check_root "$d"; echo "guard-no-audio self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
