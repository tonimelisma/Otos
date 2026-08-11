#!/usr/bin/env bash
# Keep source comments truthful: every cited current document must exist, and every
# cited numbered plan must still be present while the plan is active. This gate scans
# only app and script source so historical planning prose can remain in documentation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_root() {
  local root="$1"
  local documents plans document plan status=0
  documents="$(grep -rhoE 'docs/[A-Za-z0-9._/-]+\.md' "$root/Otos" "$root/script" 2>/dev/null | sort -u || true)"
  while IFS= read -r document; do
    [[ -z "$document" ]] && continue
    if [[ ! -f "$root/$document" ]]; then
      echo "documentation citation check failed: missing cited document $document" >&2
      status=1
    fi
  done <<< "$documents"

  plans="$(grep -rhoE 'plan [0-9]{4}' "$root/Otos" "$root/script" 2>/dev/null | sed -E 's/.*plan ([0-9]{4}).*/\1/' | sort -u || true)"
  while IFS= read -r plan; do
    [[ -z "$plan" ]] && continue
    if ! compgen -G "$root/docs/plans/${plan}-*.md" > /dev/null; then
      echo "documentation citation check failed: missing active plan document for plan $plan" >&2
      status=1
    fi
  done <<< "$plans"
  return "$status"
}

case "${1:-check}" in
check)
  check_root "$ROOT_DIR"
  echo "documentation citations: clean"
  ;;
self-test)
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  mkdir -p "$temp_dir/Otos" "$temp_dir/script" "$temp_dir/docs"
  missing_doc="docs/plans"
  printf '%s\n' "/// $missing_doc/9999-missing.md" > "$temp_dir/Otos/Bad.swift"
  if check_root "$temp_dir"; then
    echo "check-doc-citations self-test failed: seeded missing citation passed" >&2
    exit 1
  fi
  printf '%s\n' '/// docs/requirements.md' > "$temp_dir/Otos/Bad.swift"
  touch "$temp_dir/docs/requirements.md"
  check_root "$temp_dir"
  echo "check-doc-citations self-test: clean oracle"
  ;;
*)
  echo "Usage: $0 [check|self-test]" >&2
  exit 2
  ;;
esac
