#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIREMENTS="$ROOT_DIR/docs/requirements.md"
ROADMAP="$ROOT_DIR/docs/product/roadmap.md"

fail() {
  echo "requirements authority check failed: $1" >&2
  exit 1
}

if [[ ! -f "$REQUIREMENTS" ]]; then
  fail "missing docs/requirements.md"
fi

if grep -nE '\|[[:space:]]*Proposed[[:space:]]*\|' "$REQUIREMENTS"; then
  fail "docs/requirements.md must not contain Proposed requirement rows"
fi

if grep -n '`Proposed`' "$REQUIREMENTS"; then
  fail "docs/requirements.md must not define Proposed as a requirement status"
fi

if grep -n '^## Future Rows' "$REQUIREMENTS"; then
  fail "docs/requirements.md must not contain a future-row backlog section"
fi

if grep -nE '\|[[:space:]]*(Process|Tooling|Testing)[[:space:]]*\|' "$REQUIREMENTS"; then
  fail "docs/requirements.md must not contain Process/Tooling/Testing type columns (process rules live in AGENTS.md)"
fi

if [[ -f "$ROADMAP" ]] && grep -n '^Requirement IDs:' "$ROADMAP"; then
  fail "docs/product/roadmap.md must not assign requirement IDs to unimplemented planning items"
fi

# Every backtick path in Implemented-in / Tested-by cells must exist on disk.
# Skip manual: entries (they are not paths). Extract paths that look like repo paths.
missing=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  # Skip non-path tokens
  case "$path" in
    manual:*) continue ;;
    *\**) continue ;;  # globs like Otos/ are directories we allow as prefixes
  esac
  if [[ ! -e "$ROOT_DIR/$path" ]]; then
    echo "missing path cited in requirements.md: $path" >&2
    missing=1
  fi
done < <(
  # Pull backtick contents from table body rows only (skip header)
  awk '
    /^\| ID \|/ { next }
    /^\| ---/ { next }
    /^\|/ {
      # columns: ID | Requirement | Acceptance | Implemented in | Tested by
      n = split($0, cols, "|")
      # cols[1] empty, [2]=ID, [3]=req, [4]=acc, [5]=impl, [6]=tested
      for (i = 5; i <= 6; i++) {
        cell = cols[i]
        while (match(cell, /`[^`]+`/)) {
          token = substr(cell, RSTART+1, RLENGTH-2)
          print token
          cell = substr(cell, RSTART+RLENGTH)
        }
      }
    }
  ' "$REQUIREMENTS"
)

if [[ "$missing" -ne 0 ]]; then
  fail "one or more Implemented-in / Tested-by paths do not exist on disk"
fi

echo "requirements authority check: clean"
