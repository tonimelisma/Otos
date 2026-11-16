#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST=(
  # Explicit import/reorganization transfers are user initiated.
  "Otos/Services/MediaImportExecutor.swift" "Otos/Services/ReorganizationExecutor.swift"
  # User-commanded export: new files into the folder the person chose, written in the
  # system scratch folder and published without overwriting (ADR 0038).
  "Otos/Services/MediaExporter.swift"
  # Hand-off files live in Application Support's HandOff folder (ADR 0037).
  "Otos/Services/HandOffPreparer.swift"
  # Writes only the staging URL its two callers pass: the hand-off's Application Support
  # file and export's system scratch file (ADR 0037, ADR 0038).
  "Otos/Services/MediaFileWriter.swift"
  # These writers target Otos-owned thumbnails, staging, device imports, or provider materialization.
  "Otos/Services/ThumbnailStore.swift" "Otos/Services/DeviceStagingRegistry.swift"
  # The search index's vector files, in Application Support's SearchIndex folder (ADR 0048).
  "Otos/Services/SearchVectorFile.swift"
  # Deletes only an error page URLSession downloaded into the system temporary folder.
  "Otos/Services/ImmichClient.swift"
  # Owns the staging cache layout, so every path it deletes it also constructs.
  "Otos/Services/StagingLocation.swift"
  "Otos/Services/CopyfileTransfer.swift" "Otos/Services/ExclusivePublication.swift"
  "Otos/Services/CameraSourceMonitor.swift" "Otos/Services/FileMaterialization.swift"
  "Otos/Stores/CatalogStore.swift" "Otos/Stores/CatalogStorePersistence.swift"
  # Removes only files in Otos's own derived folder that no row names or would write, and
  # the retired JSONL sink's files in Application Support (ADR 0009, ADR 0015).
  "Otos/Stores/DerivedFileReconciliation.swift"
  # User-commanded Move to Trash: removeItem only after an explicit `Delete … Immediately?`
  # answer, and moveItem only to put an undone item back from the Trash (ADR 0022).
  "Otos/Services/MediaTrashCoordinator.swift"
  # DEBUG-only smoke capture: one PNG at the path the developer named, refused under
  # any library root before the write (ADR 0020).
  "Otos/Support/SmokeWindowCapture.swift"
)
is_allowlisted() { local p="$1" a; for a in "${ALLOWLIST[@]}"; do [[ "$p" == "$a" ]] && return 0; done; return 1; }
check_root() {
  local root="$1" line abs rel
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue; abs="${line%%:*}"; rel="${abs#"$root/"}"
    if ! is_allowlisted "$rel"; then echo "FAIL: unexpected filesystem writer may write into user media: $line" >&2; return 1; fi
  done < <(grep -RInE 'FileManager\.default\.(createFile|createDirectory|copyItem|moveItem|removeItem|replaceItemAt|trashItem)|\.write\(to:' "$root/Otos" --include='*.swift' || true)
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/Otos/Services"; printf 'try data.write(to: url)\n' > "$d/Otos/Services/Bad.swift"
  if check_root "$d"; then echo "guard-no-writes-into-media self-test failed" >&2; return 1; fi
  mv "$d/Otos/Services/Bad.swift" "$d/Otos/Services/MediaImportExecutor.swift"; check_root "$d"
  echo "guard-no-writes-into-media self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
