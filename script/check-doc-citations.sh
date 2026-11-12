#!/usr/bin/env bash
# Keep source comments truthful: every cited current document must exist, and every
# cited numbered plan must still be present while the plan is active. This gate scans
# only app and script source so historical planning prose can remain in documentation.
# It skips binary files (-I): Otos/ holds about 500 MB of Core ML weights and embedding
# tables, and reading them took 24 of this gate's 25 seconds for no citation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_root() {
  local root="$1"
  local documents plans document plan status=0
  documents="$(grep -rIhoE 'docs/[A-Za-z0-9._/-]+\.md' "$root/Otos" "$root/script" 2>/dev/null | sort -u || true)"
  while IFS= read -r document; do
    [[ -z "$document" ]] && continue
    if [[ ! -f "$root/$document" ]]; then
      echo "documentation citation check failed: missing cited document $document" >&2
      status=1
    fi
  done <<< "$documents"

  # docs/index.md is the one document whose job is to point at other documents,
  # so its relative links are checked even though prose elsewhere is exempt: a
  # dead link there is a navigation defect, not retained planning history. PR 292
  # deleted the then-active plan and left the index pointing at it, and this gate
  # reported clean because it scanned only source.
  local link target
  if [[ -f "$root/docs/index.md" ]]; then
    while IFS= read -r link; do
      [[ -z "$link" ]] && continue
      target="${link%%#*}"
      [[ -z "$target" ]] && continue
      if [[ ! -e "$root/docs/$target" ]]; then
        echo "documentation citation check failed: docs/index.md links missing docs/$target" >&2
        status=1
      fi
    done <<< "$(grep -oE '\]\([A-Za-z0-9._/-]+\)' "$root/docs/index.md" | sed -E 's/^\]\((.*)\)$/\1/' | sort -u)"
  fi

  plans="$(grep -rIhoE 'plan [0-9]{4}' "$root/Otos" "$root/script" 2>/dev/null | sed -E 's/.*plan ([0-9]{4}).*/\1/' | sort -u || true)"
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
  printf '%s\n' '- [gone](plans/9999-gone.md)' > "$temp_dir/docs/index.md"
  if check_root "$temp_dir"; then
    echo "check-doc-citations self-test failed: seeded dead index link passed" >&2
    exit 1
  fi
  printf '%s\n' '- [requirements](requirements.md)' > "$temp_dir/docs/index.md"
  check_root "$temp_dir"
  echo "check-doc-citations self-test: clean oracle"
  ;;
*)
  echo "Usage: $0 [check|self-test]" >&2
  exit 2
  ;;
esac
