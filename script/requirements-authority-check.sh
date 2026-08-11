#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REQUIREMENTS="$ROOT_DIR/docs/requirements.md"
DEFAULT_ROADMAP="$ROOT_DIR/docs/product/roadmap.md"

fail() {
  echo "requirements authority check failed: $1" >&2
  exit 1
}

# ALLOWLIST holds the rows not yet migrated. It only ever shrinks; a new row may
# never be added to it. The count gate below makes accidental re-expansion fail.
ALLOWLIST=(
  "APP-001" "APP-002" "APP-003" "APP-006" "APP-008" "APP-009" "APP-010" "APP-011"
  "APP-013" "APP-014" "APP-015" "APP-017" "APP-018" "APP-019" "APP-020" "APP-021"
  "APP-022" "APP-023" "ARC-001" "ARC-002" "ARC-002A" "ARC-003" "ARC-004" "ARC-005"
  "ARC-007" "ARC-008" "ARC-009" "ARC-010" "ARC-011" "ARC-012" "ARC-013" "ARC-014"
  "ARC-015" "ARC-016" "ARC-018" "ARC-019" "ARC-021" "ARC-022" "ARC-023" "ARC-026"
  "ARC-031" "ARC-033" "ARC-034" "ARC-035" "ARC-037" "ARC-038" "ARC-041" "ARC-042"
  "ARC-043" "ARC-044" "ARC-045" "ARC-046" "ARC-046A" "ARC-048" "ARC-049"
  "ARC-050" "ARC-051" "ARC-053" "ENR-001" "ENR-002" "ENR-003" "ENR-004" "ENR-005"
  "ENR-007" "ENR-008" "ENR-009" "ENR-010" "ENR-011" "ENR-012" "ENR-013" "ENR-014"
  "ENR-015" "MED-001" "MED-004"
)
ALLOWLIST_MAX_COUNT=74

is_allowlisted() {
  local id="$1"
  for a in "${ALLOWLIST[@]}"; do
    [[ "$a" == "$id" ]] && return 0
  done
  return 1
}

check_root() {
  local root="$1"
  local requirements="$root/docs/requirements.md"
  local roadmap="$root/docs/product/roadmap.md"

  if [[ ! -f "$requirements" ]]; then
    fail "missing docs/requirements.md"
  fi

  if grep -nE '\|[[:space:]]*Proposed[[:space:]]*\|' "$requirements"; then
    fail "docs/requirements.md must not contain Proposed requirement rows"
  fi

  if grep -n '`Proposed`' "$requirements"; then
    fail "docs/requirements.md must not define Proposed as a requirement status"
  fi

  if grep -n '^## Future Rows' "$requirements"; then
    fail "docs/requirements.md must not contain a future-row backlog section"
  fi

  if grep -nE '\|[[:space:]]*(Process|Tooling|Testing)[[:space:]]*\|' "$requirements"; then
    fail "docs/requirements.md must not contain Process/Tooling/Testing type columns (process rules live in AGENTS.md)"
  fi

  if [[ -f "$roadmap" ]] && grep -n '^Requirement IDs:' "$roadmap"; then
    fail "docs/product/roadmap.md must not assign requirement IDs to unimplemented planning items"
  fi

  if (( ${#ALLOWLIST[@]} > ALLOWLIST_MAX_COUNT )); then
    fail "requirements allowlist grew to ${#ALLOWLIST[@]} rows (maximum ${ALLOWLIST_MAX_COUNT})"
  fi

  # Literal pipes inside cells must be escaped. Table rows are pipe-delimited with
  # exactly 7 fields (leading empty + 5 columns + trailing empty). Any extra pipe
  # inside a cell without escaping breaks the field count and fails here.
  # Check all markdown table rows for structural health.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    nf=$(printf '%s\n' "$line" | awk -F'|' '{print NF}')
    if [[ "$nf" != "7" ]]; then
      fail "requirement row has $nf pipe-delimited fields, expected 7 (literal pipes inside cells must be escaped): $line"
    fi
  done < <(grep -E '^\|' "$requirements" || true)

  # Check each requirement row — portable awk, no BSD/GNU sed alternation.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    id=$(printf '%s\n' "$line" | awk -F'|' '{gsub(/^ *| *$/,"",$2); print $2}')
    # Skip header and separator rows
    if [[ "$id" == "ID" ]] || [[ "$id" == "---" ]]; then
      continue
    fi
    if [[ -z "$id" ]]; then
      fail "requirement row missing ID: $line"
    fi
    if ! [[ "$id" =~ ^(ARC|APP|ENR|MED)-[0-9]+[A-Z]*$ ]]; then
      fail "requirement row has unrecognized ID '$id': $line"
    fi
    if is_allowlisted "$id"; then
      continue
    fi
    req=$(printf '%s\n' "$line" | awk -F'|' '{gsub(/^ *| *$/,"",$3); print $3}')
    acc=$(printf '%s\n' "$line" | awk -F'|' '{gsub(/^ *| *$/,"",$4); print $4}')
    tested=$(printf '%s\n' "$line" | awk -F'|' '{gsub(/^ *| *$/,"",$6); print $6}')
    if [[ ${#req} -gt 400 ]]; then
      fail "requirement $id exceeds 400 chars (has ${#req}): $req"
    fi
    if [[ ${#acc} -gt 400 ]]; then
      fail "acceptance for $id exceeds 400 chars (has ${#acc})"
    fi
    if printf '%s\n' "$line" | grep -qE 'animatingDifferences|NSAnimationContext|PRAGMA|COALESCE|INDEXED BY|plan [0-9]{4}|n ≥|k='; then
      fail "requirement $id contains implementation token"
    fi
    if printf '%s\n' "$line" | grep -qE '[0-9]+ms|[0-9]+ ms'; then
      fail "requirement $id contains bare timing constant"
    fi
    if printf '%s\n' "$tested" | grep -q "manual:"; then
      fail "requirement $id uses manual: verification (not machine-checked)"
    fi
    if [[ "$tested" == "—" ]] || [[ -z "$tested" ]]; then
      fail "requirement $id has no Tested by path"
    fi

    # Verification-cell grammar:
    # - executable proof: backticked `path#symbol` entries
    # - honest debt: `unverified: <specific clause and reason>`
    # `manual:` is already rejected above. At least one of the two valid forms must be present.
    has_unverified=0
    if printf '%s\n' "$tested" | grep -q "unverified:"; then
      # Require non-empty reason after colon
      if ! printf '%s\n' "$tested" | grep -qE 'unverified:[[:space:]]*[^[:space:]]+'; then
        fail "requirement $id has malformed unverified: entry (must be 'unverified: <specific clause and reason>'): $tested"
      fi
      has_unverified=1
    fi

    # Extract backtick tokens and validate each contains '#'
    # Find all `...` occurrences
    backtick_tokens=$(printf '%s\n' "$tested" | grep -oE '`[^`]+`' || true)
    has_valid_proof=0
    invalid_backtick=0
    if [[ -n "$backtick_tokens" ]]; then
      while IFS= read -r token; do
        [[ -z "$token" ]] && continue
        inner="${token#\`}"
        inner="${inner%\`}"
        if [[ "$inner" == *"#"* ]]; then
          has_valid_proof=1
        else
          # Backtick without # is not a valid proof; treat as invalid grammar unless it's unverified inside backticks
          if [[ "$inner" == unverified:* ]]; then
            has_unverified=1
          else
            invalid_backtick=1
          fi
        fi
      done <<< "$backtick_tokens"
      if [[ "$invalid_backtick" -ne 0 ]]; then
        fail "requirement $id has invalid verification grammar (backtick entries must be path#symbol): $tested"
      fi
    fi

    if [[ "$has_valid_proof" -eq 0 ]] && [[ "$has_unverified" -eq 0 ]]; then
      fail "requirement $id Tested by has invalid verification grammar (must contain path#symbol or unverified: <reason>): $tested"
    fi

    # For each valid proof token, verify file/symbol exists. Do not claim semantics, only existence.
    named_tests=$(printf '%s\n' "$tested" | grep -oE '`[^`]+#[^`]+`' || true)
    if [[ -n "$named_tests" ]]; then
      while IFS= read -r token; do
        [[ -z "$token" ]] && continue
        token="${token#\`}"
        token="${token%\`}"
        test_path="${token%%#*}"
        test_name="${token#*#}"
        # Trim whitespace
        test_path=$(printf '%s\n' "$test_path" | awk '{gsub(/^ *| *$/,"",$0); print}')
        test_name=$(printf '%s\n' "$test_name" | awk '{gsub(/^ *| *$/,"",$0); print}')
        test_file="$root/$test_path"
        if [[ "$test_path" == *.swift ]]; then
          if ! grep -Eq "func[[:space:]]+$test_name[[:space:]]*\\(" "$test_file" 2>/dev/null; then
            fail "requirement $id names missing Swift test $token"
          fi
        elif [[ "$test_path" == *.sh ]]; then
          if ! grep -Fq "$test_name" "$test_file" 2>/dev/null; then
            fail "requirement $id names missing script self-test $token"
          fi
        else
          fail "requirement $id names unsupported test file $test_path"
        fi
      done <<< "$named_tests"
    fi
  done < <(grep -E '^\|' "$requirements" || true)

  # Every backtick path in Implemented-in / Tested-by cells must exist on disk.
  # Traceability only — validates that cited paths are real files, not that they prove semantics.
  missing=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    path="${path%%#*}"
    case "$path" in
      manual:*) continue ;;
      unverified:*) continue ;;
      *\**) continue ;;
    esac
    # Trim
    path=$(printf '%s\n' "$path" | awk '{gsub(/^ *| *$/,"",$0); print}')
    [[ -z "$path" ]] && continue
    if [[ ! -e "$root/$path" ]]; then
      echo "missing path cited in requirements.md: $path" >&2
      missing=1
    fi
  done < <(
    awk '
      /^\| ID \|/ { next }
      /^\| ---/ { next }
      /^\|/ {
        n = split($0, cols, "|")
        for (i = 5; i <= 6; i++) {
          cell = cols[i]
          while (match(cell, /`[^`]+`/)) {
            token = substr(cell, RSTART+1, RLENGTH-2)
            print token
            cell = substr(cell, RSTART+RLENGTH)
          }
        }
      }
    ' "$requirements"
  )

  if [[ "$missing" -ne 0 ]]; then
    fail "one or more Implemented-in / Tested-by paths do not exist on disk"
  fi

  echo "requirements authority check: clean"
}

self_test() {
  echo "requirements authority check self-test: start"

  # Helper: create minimal valid requirements.md header
  make_header() {
    local file="$1"
    cat > "$file" <<'HEADER'
# Otos Requirements

| ID | Requirement | Acceptance example | Implemented in | Tested by |
| --- | --- | --- | --- | --- |
HEADER
  }

  # Helper: run check_root expecting failure (non-zero) or success (zero)
  # Run in subshell so fail()'s exit does not kill the self-test harness (set -e).
  expect_fail() {
    local desc="$1"
    local tmpRoot="$2"
    if (check_root "$tmpRoot") >/dev/null 2>&1; then
      echo "self-test failed: $desc should have failed but passed" >&2
      exit 1
    else
      echo "self-test ok: $desc correctly failed"
    fi
  }

  expect_pass() {
    local desc="$1"
    local tmpRoot="$2"
    if ! (check_root "$tmpRoot") >/dev/null 2>&1; then
      echo "self-test failed: $desc should have passed but failed" >&2
      (check_root "$tmpRoot") 2>&1 | head -n 20 >&2
      exit 1
    else
      echo "self-test ok: $desc correctly passed"
    fi
  }

  tmpBase=$(mktemp -d)
  trap 'rm -rf "$tmpBase"' EXIT

  # 1. malformed column count — 8 fields instead of 7
  t="$tmpBase/t1"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | Extra | `Otos/Foo.swift` | `OtosTests/FooTests.swift#testFoo` |' >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "malformed column count" "$t"

  # 2. missing/invalid ID
  t="$tmpBase/t2"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| BAD-001 | Req | Acc | `Otos/Foo.swift` | `OtosTests/FooTests.swift#testFoo` |' >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "missing/invalid ID" "$t"

  # 3. overlong requirement cell (>400 chars)
  t="$tmpBase/t3"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  longReq=$(printf 'a%.0s' {1..401})
  echo "| ARC-999 | $longReq | Acc | \`Otos/Foo.swift\` | \`OtosTests/FooTests.swift#testFoo\` |" >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "overlong requirement" "$t"

  # 4. overlong acceptance cell (>400 chars)
  t="$tmpBase/t4"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  longAcc=$(printf 'a%.0s' {1..401})
  echo "| ARC-999 | Req | $longAcc | \`Otos/Foo.swift\` | \`OtosTests/FooTests.swift#testFoo\` |" >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "overlong acceptance" "$t"

  # 5. forbidden implementation token
  t="$tmpBase/t5"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req with animatingDifferences | Acc | `Otos/Foo.swift` | `OtosTests/FooTests.swift#testFoo` |' >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "forbidden implementation token" "$t"

  # 6. missing implementation/test path
  t="$tmpBase/t6"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/NoSuch.swift` | `OtosTests/FooTests.swift#testFoo` |' >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "missing implementation path" "$t"

  # 7. missing Swift test symbol
  t="$tmpBase/t7"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/Foo.swift` | `OtosTests/FooTests.swift#noSuchTest` |' >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "missing Swift test symbol" "$t"

  # 8. manual: verification
  t="$tmpBase/t8"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/Foo.swift` | manual: do thing |' >> "$t/docs/requirements.md"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "manual: verification" "$t"

  # 9. invalid verification grammar (no backtick proof nor unverified)
  t="$tmpBase/t9"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/Foo.swift` | some random text |' >> "$t/docs/requirements.md"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "invalid verification grammar" "$t"

  # 10. one valid named proof — should pass
  t="$tmpBase/t10"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/Foo.swift` | `OtosTests/FooTests.swift#testFoo` |' >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() {}" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_pass "one valid named proof" "$t"

  # 11. one valid bounded unverified entry — should pass
  t="$tmpBase/t11"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/Foo.swift` | unverified: ledger release not yet proven until Stage 4 |' >> "$t/docs/requirements.md"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_pass "one valid bounded unverified entry" "$t"

  # 12. script self-test proof — should pass when symbol exists
  t="$tmpBase/t12"; mkdir -p "$t/docs" "$t/script"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/Foo.swift` | `script/foo.sh#testBar` |' >> "$t/docs/requirements.md"
  echo -e "#!/usr/bin/env bash\n# testBar" > "$t/script/foo.sh"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_pass "valid script self-test proof" "$t"

  # 13. missing script self-test symbol — should fail
  t="$tmpBase/t13"; mkdir -p "$t/docs" "$t/script"
  make_header "$t/docs/requirements.md"
  echo '| ARC-999 | Req | Acc | `Otos/Foo.swift` | `script/foo.sh#noSuch` |' >> "$t/docs/requirements.md"
  echo -e "#!/usr/bin/env bash\n# testBar" > "$t/script/foo.sh"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "missing script self-test symbol" "$t"

  rm -rf "$tmpBase"
  trap - EXIT
  echo "requirements authority check self-test: clean"
}

# Entry point — default is real repository check, "self-test" runs isolated fixtures.
case "${1:-}" in
  self-test)
    self_test
    ;;
  check)
    check_root "${2:-$ROOT_DIR}"
    ;;
  "")
    check_root "$ROOT_DIR"
    ;;
  *)
    echo "usage: $0 [check [root]|self-test]" >&2
    exit 1
    ;;
esac
