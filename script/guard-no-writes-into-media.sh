#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard-scan.sh"
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST=(
  # Explicit import/reorganization transfers are user initiated.
  "OtosKit/Services/MediaImportExecutor.swift" "OtosKit/Services/ReorganizationExecutor.swift"
  # User-commanded export: new files into the folder the person chose, written in the
  # system scratch folder and published without overwriting (ADR 0038).
  "OtosKit/Services/MediaExporter.swift"
  # User-commanded Help ▸ Export Diagnostics…: one new folder into the folder the person
  # chose, staged in the system scratch folder and published without replacing (ADR 0060).
  "OtosKit/Services/DiagnosticsExport.swift"
  # Keeps MetricKit's reports in Application Support's Diagnostics folder (ADR 0060).
  "OtosKit/Services/MetricKitRecorder.swift"
  # Hand-off files live in Application Support's HandOff folder (ADR 0037).
  "OtosKit/Services/HandOffPreparer.swift"
  # Writes only the staging URL its two callers pass: the hand-off's Application Support
  # file and export's system scratch file (ADR 0037, ADR 0038).
  "OtosKit/Services/MediaFileWriter.swift"
  # These writers target Otos-owned thumbnails, staging, device imports, or provider materialization.
  "OtosKit/Services/ThumbnailStore.swift" "OtosKit/Services/DeviceStagingRegistry.swift"
  # The search index's vector files, in Application Support's SearchIndex folder (ADR 0048).
  "OtosKit/Services/SearchVectorFile.swift"
  # Deletes only an error page URLSession downloaded into the system temporary folder.
  "OtosKit/Services/ImmichClient.swift"
  # Owns the staging cache layout, so every path it deletes it also constructs.
  "OtosKit/Services/StagingLocation.swift"
  "OtosKit/Services/CopyfileTransfer.swift" "OtosKit/Services/ExclusivePublication.swift"
  "OtosKit/Services/CameraSourceMonitor.swift" "OtosKit/Services/FileMaterialization.swift"
  "OtosKit/Stores/CatalogStore.swift" "OtosKit/Stores/CatalogStorePersistence.swift"
  # Promotes, renames and removes only files in Otos's own derived folder, writes and removes
  # its session marker beside it, and removes the retired JSONL sink's files in Application
  # Support (ADR 0009, ADR 0015).
  "OtosKit/Stores/DerivedFileReconciliation.swift"
  # User-commanded Move to Trash: removeItem only after an explicit `Delete … Immediately?`
  # answer, and moveItem only to put an undone item back from the Trash (ADR 0022).
  "OtosKit/Services/MediaTrashCoordinator.swift"
  # DEBUG-only smoke capture: one PNG at the path the developer named, refused under
  # any library root before the write (ADR 0020).
  "OtosKit/Support/SmokeWindowCapture.swift"
)
is_allowlisted() { local p="$1" a; for a in "${ALLOWLIST[@]}"; do [[ "$p" == "$a" ]] && return 0; done; return 1; }
check_root() {
  local root="$1" line abs rel
  guard_scans guard-no-writes-into-media "$root/OtosKit" || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue; abs="${line%%:*}"; rel="${abs#"$root/"}"
    if ! is_allowlisted "$rel"; then echo "FAIL: unexpected filesystem writer may write into user media: $line" >&2; return 1; fi
  done < <(grep -RInE 'FileManager\.default\.(createFile|createDirectory|copyItem|moveItem|removeItem|replaceItemAt|trashItem)|\.write\(to:' "$root/OtosKit" --include='*.swift' || true)
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  if check_root "$d/missing" 2>/dev/null; then echo "guard-no-writes-into-media self-test failed (a missing scan root passed)" >&2; return 1; fi
  mkdir -p "$d/OtosKit/Services"; printf 'try data.write(to: url)\n' > "$d/OtosKit/Services/Bad.swift"
  if check_root "$d"; then echo "guard-no-writes-into-media self-test failed" >&2; return 1; fi
  mv "$d/OtosKit/Services/Bad.swift" "$d/OtosKit/Services/MediaImportExecutor.swift"; check_root "$d"
  echo "guard-no-writes-into-media self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
