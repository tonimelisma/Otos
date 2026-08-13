#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST=(
  # Explicit import/reorganization transfers are user initiated.
  "Otos/Services/MediaImportExecutor.swift" "Otos/Services/ReorganizationExecutor.swift"
  # These writers target Otos-owned thumbnails, staging, device imports, or provider materialization.
  "Otos/Services/ThumbnailStore.swift" "Otos/Services/DeviceStagingRegistry.swift"
  "Otos/Services/CopyfileTransfer.swift" "Otos/Services/ExclusivePublication.swift"
  "Otos/Services/CameraSourceMonitor.swift" "Otos/Services/FileMaterialization.swift"
  "Otos/Stores/CatalogStore.swift" "Otos/Stores/CatalogStorePersistence.swift"
)
is_allowlisted() { local p="$1" a; for a in "${ALLOWLIST[@]}"; do [[ "$p" == "$a" ]] && return 0; done; return 1; }
check_root() {
  local root="$1" line abs rel
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue; abs="${line%%:*}"; rel="${abs#"$root/"}"
    if ! is_allowlisted "$rel"; then echo "FAIL: unexpected filesystem writer may write into user media: $line" >&2; return 1; fi
  done < <(grep -RInE 'FileManager\.default\.(createFile|createDirectory|copyItem|moveItem|removeItem|replaceItemAt)|\.write\(to:' "$root/Otos" --include='*.swift' || true)
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/Otos/Services"; printf 'try data.write(to: url)\n' > "$d/Otos/Services/Bad.swift"
  if check_root "$d"; then echo "guard-no-writes-into-media self-test failed" >&2; return 1; fi
  mv "$d/Otos/Services/Bad.swift" "$d/Otos/Services/MediaImportExecutor.swift"; check_root "$d"
  echo "guard-no-writes-into-media self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
