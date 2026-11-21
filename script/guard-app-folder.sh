#!/usr/bin/env bash
# The app target compiles `Otos/` and the OtosKit framework compiles `OtosKit/`, each through
# its own synchronized group (ADR 0023), so a file's folder is its target. The app is
# `main.swift`, `Assets.xcassets/` and `Otos.icon/`; any other file under `Otos/` — a source,
# a model, a data table, of any type — would be built into the app instead of the framework.
# A commit that adds a file in a new folder under `Otos/` rebases across the move cleanly
# and lands there (docs/research/2026-11-20-edit-access-and-move-replay.md, E8), so this
# guard rejects every such file. `.DS_Store` is Finder's, ignored by git and by Xcode.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard-scan.sh"
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
check_root() {
  local root="$1" app="$1/Otos" path strays=()
  guard_scans guard-app-folder "$app" "$app/main.swift" || return 1
  while IFS= read -r -d '' path; do
    case "${path#"$app"/}" in
      main.swift | Assets.xcassets/* | Otos.icon/* | .DS_Store | */.DS_Store) ;;
      *) strays+=("${path#"$root"/}") ;;
    esac
  done < <(find "$app" ! -type d -print0)
  if (( ${#strays[@]} > 0 )); then
    printf 'FAIL: guard-app-folder: the app folder holds only main.swift, Assets.xcassets/ and Otos.icon/; move into OtosKit/: %s\n' "${strays[@]}" >&2
    return 1
  fi
}
self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  if check_root "$d/missing" 2>/dev/null; then echo "guard-app-folder self-test failed (a missing scan root passed)" >&2; return 1; fi
  mkdir -p "$d/Otos/Assets.xcassets/AppIcon.appiconset" "$d/Otos/Otos.icon/Assets"
  : > "$d/Otos/main.swift"
  : > "$d/Otos/Assets.xcassets/Contents.json"
  : > "$d/Otos/Otos.icon/icon.json"
  : > "$d/Otos/.DS_Store"
  check_root "$d"
  mkdir -p "$d/Otos/NewFeature"; : > "$d/Otos/NewFeature/Table.tsv"
  if check_root "$d" 2>/dev/null; then echo "guard-app-folder self-test failed (a resource in a new folder passed)" >&2; return 1; fi
  rm -r "$d/Otos/NewFeature"
  : > "$d/Otos/Stray.swift"
  if check_root "$d" 2>/dev/null; then echo "guard-app-folder self-test failed (a source beside main.swift passed)" >&2; return 1; fi
  rm "$d/Otos/Stray.swift"
  : > "$d/Otos/Assets.xcassets.swift"
  if check_root "$d" 2>/dev/null; then echo "guard-app-folder self-test failed (a file named like an allowed folder passed)" >&2; return 1; fi
  rm "$d/Otos/Assets.xcassets.swift"
  check_root "$d"
  echo "guard-app-folder self-test: clean oracle"
}
case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
