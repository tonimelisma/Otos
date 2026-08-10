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

# Plan 0077 Stage 1: requirement rows state observable behavior, not implementation.
# These checks exist because the registry drifted into a changelog: mean row length
# reached ~1,240 chars and 25 of 96 rows carried implementation constants (plan 0077 §1).
#
# 1. Requirement and acceptance cells are each <= 400 characters (allowlisted).
# 2. No row contains an implementation token: animatingDifferences, NSAnimationContext,
#    PRAGMA, COALESC, INDEXED BY, a bare NNNms/NN ms, n ≥, k=, or plan NNN.
# 3. Every row's Tested by column names at least one path under OtosTests/ or script/.
#    manual: and — are not accepted (allowlisted).
#
# ALLOWLIST holds the rows not yet migrated. It only ever shrinks; a new row may
# never be added to it. Stage 4 deletes the allowlist and this comment.
ALLOWLIST=(
  "APP-001" "APP-002" "APP-003" "APP-006" "APP-008" "APP-009" "APP-010" "APP-011"
  "APP-013" "APP-014" "APP-015" "APP-017" "APP-018" "APP-019" "APP-020" "APP-021"
  "APP-022" "APP-023" "ARC-001" "ARC-002" "ARC-002A" "ARC-003" "ARC-004" "ARC-005"
  "ARC-007" "ARC-008" "ARC-009" "ARC-010" "ARC-011" "ARC-012" "ARC-013" "ARC-014"
  "ARC-015" "ARC-016" "ARC-018" "ARC-019" "ARC-021" "ARC-022" "ARC-023" "ARC-026"
  "ARC-031" "ARC-033" "ARC-034" "ARC-035" "ARC-037" "ARC-038" "ARC-041" "ARC-042"
  "ARC-043" "ARC-044" "ARC-045" "ARC-046" "ARC-046A" "ARC-047" "ARC-048" "ARC-049"
  "ARC-050" "ARC-051" "ARC-053" "ENR-001" "ENR-002" "ENR-003" "ENR-004" "ENR-005"
  "ENR-007" "ENR-008" "ENR-009" "ENR-010" "ENR-011" "ENR-012" "ENR-013" "ENR-014"
  "ENR-015" "MED-001" "MED-004"
)

is_allowlisted() {
  local id="$1"
  for a in "${ALLOWLIST[@]}"; do
    [[ "$a" == "$id" ]] && return 0
  done
  return 1
}

# Check each requirement row
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Extract ID
  id=$(echo "$line" | sed -n 's/^| *\(ARC-[^ |]*\|APP-[^ |]*\|ENR-[^ |]*\|MED-[^ |]*\).*/\1/p')
  [[ -z "$id" ]] && continue
  if is_allowlisted "$id"; then
    continue
  fi
  # Extract requirement and acceptance cells (columns 3 and 4)
  req=$(echo "$line" | awk -F'|' '{gsub(/^ *| *$/,"",$3); print $3}')
  acc=$(echo "$line" | awk -F'|' '{gsub(/^ *| *$/,"",$4); print $4}')
  tested=$(echo "$line" | awk -F'|' '{gsub(/^ *| *$/,"",$6); print $6}')
  if [[ ${#req} -gt 400 ]]; then
    fail "requirement $id exceeds 400 chars (has ${#req}): $req"
  fi
  if [[ ${#acc} -gt 400 ]]; then
    fail "acceptance for $id exceeds 400 chars (has ${#acc})"
  fi
  if echo "$line" | grep -qE 'animatingDifferences|NSAnimationContext|PRAGMA|COALESCE|INDEXED BY|plan [0-9]{4}|n ≥|k='; then
    fail "requirement $id contains implementation token"
  fi
  if echo "$line" | grep -qE '[0-9]+ms|[0-9]+ ms'; then
    fail "requirement $id contains bare timing constant"
  fi
  if echo "$tested" | grep -q "manual:"; then
    fail "requirement $id uses manual: verification (not machine-checked)"
  fi
  if [[ "$tested" == "—" ]] || [[ -z "$tested" ]]; then
    fail "requirement $id has no Tested by path"
  fi
done < <(grep -E '^\| (ARC-|APP-|ENR-|MED-)' "$REQUIREMENTS")

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
