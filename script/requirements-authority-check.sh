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

if [[ -f "$ROADMAP" ]] && grep -n '^Requirement IDs:' "$ROADMAP"; then
  fail "docs/product/roadmap.md must not assign requirement IDs to unimplemented planning items"
fi

echo "requirements authority check: clean"
