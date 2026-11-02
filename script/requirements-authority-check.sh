#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The whole check is one Python pass over docs/requirements.md, reading each cited
# file once. A process per row or per citation would be thousands of spawns, and
# this gate runs before every build in script/check.sh. `self-test` below drives
# this function as a black box against seeded fixtures.
check_root() {
  python3 - "$1" <<'PY'
import os
import re
import sys
from collections import Counter

root = sys.argv[1]
requirements = os.path.join(root, "docs/requirements.md")
roadmap = os.path.join(root, "docs/product/roadmap.md")


def fail(message):
    print(f"requirements authority check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def strip_spaces(text):
    return text.strip(" ")


def report_matches(lines, pattern):
    """grep -n: print every matching line, report whether any matched."""
    matched = False
    for number, line in enumerate(lines, start=1):
        if re.search(pattern, line):
            print(f"{number}:{line}")
            matched = True
    return matched


if not os.path.isfile(requirements):
    fail("missing docs/requirements.md")

lines = open(requirements, encoding="utf-8").read().splitlines()

if report_matches(lines, r"\|\s*Proposed\s*\|"):
    fail("docs/requirements.md must not contain Proposed requirement rows")
if report_matches(lines, r"`Proposed`"):
    fail("docs/requirements.md must not define Proposed as a requirement status")
if report_matches(lines, r"^## Future Rows"):
    fail("docs/requirements.md must not contain a future-row backlog section")
if report_matches(lines, r"\|\s*(Process|Tooling|Testing)\s*\|"):
    fail("docs/requirements.md must not contain Process/Tooling/Testing type columns (process rules live in AGENTS.md)")
if os.path.isfile(roadmap) and report_matches(open(roadmap, encoding="utf-8").read().splitlines(), r"^Requirement IDs:"):
    fail("docs/product/roadmap.md must not assign requirement IDs to unimplemented planning items")

rows = [line for line in lines if line.startswith("|")]

# Literal pipes inside cells must be escaped. Table rows are pipe-delimited with
# exactly 7 fields (leading empty + 5 columns + trailing empty). Any extra pipe
# inside a cell without escaping breaks the field count and fails here.
for line in rows:
    fields = len(line.split("|"))
    if fields != 7:
        fail(f"requirement row has {fields} pipe-delimited fields, expected 7 (literal pipes inside cells must be escaped): {line}")

sources = {}


def source_of(path):
    if path not in sources:
        try:
            sources[path] = open(path, encoding="utf-8").read()
        except OSError:
            sources[path] = None
    return sources[path]


def check_swift_test_body(path, name, token, requirement_id):
    source = source_of(path)
    declaration = None if source is None else re.search(r"\bfunc\s+" + re.escape(name) + r"\s*\([^)]*\)[^{]*\{", source)
    if declaration is None:
        fail(f"requirement {requirement_id} names missing Swift test {token}")
    opening = source.find("{", declaration.start(), declaration.end())
    depth = 0
    closing = None
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                closing = index
                break
    if closing is None:
        fail(f"requirement {requirement_id} has unterminated Swift test {path}#{name}")
    body = re.sub(r"#expect\s*\(\s*true\b[^\n]*\)", "", source[opening + 1:closing])
    if not any(token in body for token in ("#expect(", "#require(", "Issue.record(")) and re.search(
        r"\b(?:assert[A-Za-z_]*|waitFor[A-Za-z_]*|verify[A-Za-z_]*)\s*\(", body
    ) is None:
        fail(f"requirement {requirement_id} cites a Swift test with no failing assertion {path}#{name}")


shared_proofs = Counter()
for line in rows:
    cells = line.split("|")
    requirement_id = strip_spaces(cells[1])
    if requirement_id in ("ID", "---"):
        continue
    if not requirement_id:
        fail(f"requirement row missing ID: {line}")
    if not re.fullmatch(r"(ARC|APP|ENR|MED)-[0-9]+[A-Z]*", requirement_id):
        fail(f"requirement row has unrecognized ID '{requirement_id}': {line}")
    requirement, acceptance, tested = strip_spaces(cells[2]), strip_spaces(cells[3]), strip_spaces(cells[5])

    if re.search(r"animatingDifferences|NSAnimationContext|PRAGMA|COALESCE|INDEXED BY|plan [0-9]{4}|n ≥|k=", f"{requirement} {acceptance}"):
        fail(f"requirement {requirement_id} contains implementation token")
    if re.search(r"[0-9]+ms|[0-9]+ ms", line):
        fail(f"requirement {requirement_id} contains bare timing constant")
    if "manual:" in tested:
        fail(f"requirement {requirement_id} uses manual: verification (not machine-checked)")
    if tested in ("—", ""):
        fail(f"requirement {requirement_id} has no Tested by path")

    # Verification-cell grammar:
    # - executable proof: backticked `path#symbol` entries
    # - honest debt: `unverified: <specific clause and reason>`
    # `manual:` is already rejected above. At least one of the two valid forms must be present.
    has_unverified = False
    if "unverified:" in tested:
        if not re.search(r"unverified:\s*\S+", tested):
            fail(f"requirement {requirement_id} has malformed unverified: entry (must be 'unverified: <specific clause and reason>'): {tested}")
        has_unverified = True
    has_valid_proof = False
    for inner in re.findall(r"`([^`]+)`", tested):
        if "#" in inner:
            has_valid_proof = True
        elif inner.startswith("unverified:"):
            has_unverified = True
        else:
            fail(f"requirement {requirement_id} has invalid verification grammar (backtick entries must be path#symbol): {tested}")
    if not has_valid_proof and not has_unverified:
        fail(f"requirement {requirement_id} Tested by has invalid verification grammar (must contain path#symbol or unverified: <reason>): {tested}")

    # For each proof token, verify the file and symbol exist. Existence only, plus
    # a Swift test's body must be able to fail.
    for token in re.findall(r"`([^`]+#[^`]+)`", tested):
        test_path, test_name = (strip_spaces(part) for part in token.split("#", 1))
        test_file = os.path.join(root, test_path)
        if test_path.endswith(".swift"):
            check_swift_test_body(test_file, test_name, token, requirement_id)
            shared_proofs[token] += 1
        elif test_path.endswith(".sh"):
            source = source_of(test_file)
            if source is None or test_name not in source:
                fail(f"requirement {requirement_id} names missing script self-test {token}")
        else:
            fail(f"requirement {requirement_id} names unsupported test file {test_path}")

for token, count in sorted(shared_proofs.items()):
    if count > 6:
        print(f"requirements authority warning: proof {token} is cited by {count} rows", file=sys.stderr)

# Every backtick path in Implemented-in / Tested-by cells must exist on disk.
# Traceability only — validates that cited paths are real files, not that they prove semantics.
missing = False
for line in rows:
    if line.startswith("| ID |") or line.startswith("| ---"):
        continue
    cells = line.split("|")
    for cell in cells[4:6]:
        for token in re.findall(r"`([^`]+)`", cell):
            path = token.split("#", 1)[0]
            if path.startswith(("manual:", "unverified:")) or "*" in path:
                continue
            path = strip_spaces(path)
            if path and not os.path.exists(os.path.join(root, path)):
                print(f"missing path cited in requirements.md: {path}", file=sys.stderr)
                missing = True
if missing:
    fail("one or more Implemented-in / Tested-by paths do not exist on disk")

print("requirements authority check: clean")
PY
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

  # 3. long requirement cell (401 chars) — no length cap, should pass
  t="$tmpBase/t3"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  longReq=$(printf 'a%.0s' {1..401})
  echo "| ARC-999 | $longReq | Acc | \`Otos/Foo.swift\` | \`OtosTests/FooTests.swift#testFoo\` |" >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() { #expect(1 == 1) }" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_pass "long requirement (no length cap)" "$t"

  # 4. long acceptance cell (401 chars) — no length cap, should pass
  t="$tmpBase/t4"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  longAcc=$(printf 'a%.0s' {1..401})
  echo "| ARC-999 | Req | $longAcc | \`Otos/Foo.swift\` | \`OtosTests/FooTests.swift#testFoo\` |" >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() { #expect(1 == 1) }" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_pass "long acceptance (no length cap)" "$t"

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
  echo -e "import Foundation\nfunc testFoo() { #expect(1 == 1) }" > "$t/OtosTests/FooTests.swift"
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

  # 14. multibyte — 400 chars must pass (length cap removed, kept as regression)
  t="$tmpBase/t14"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  mbReq=$(printf 'a%.0s' {1..398})"∪∪"
  echo "| ARC-999 | $mbReq | Acc | \`Otos/Foo.swift\` | \`OtosTests/FooTests.swift#testFoo\` |" >> "$t/docs/requirements.md"
  echo -e "import Foundation\nfunc testFoo() { #expect(1 == 1) }" > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_pass "multibyte 400 chars passes (no length cap)" "$t"

  # 15. tautological Swift proof — must fail
  t="$tmpBase/t15"; mkdir -p "$t/docs" "$t/OtosTests"
  make_header "$t/docs/requirements.md"
  printf '%s\n' '| ARC-999 | Req | Acc | `Otos/Foo.swift` | `OtosTests/FooTests.swift#testFoo` |' >> "$t/docs/requirements.md"
  printf '%s\n' 'import Foundation' 'func testFoo() { #expect(true, "tautology") }' > "$t/OtosTests/FooTests.swift"
  mkdir -p "$t/Otos"; touch "$t/Otos/Foo.swift"
  expect_fail "tautological Swift proof" "$t"

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
