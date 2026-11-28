#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Checks that docs/requirements.md holds only current, implemented behavior and that the
# Validates tags in the Swift tests sit on tests that can fail. script/process-check owns the
# rest of the traceability: each ID declared once, every tag naming a declared ID, and
# [verified] / unverified: agreeing with the tags.
#
# The whole check is one Python pass, reading each test file once: a process per item or per
# tag would be thousands of spawns, and this gate runs before every build in script/check.sh.
# `self-test` below drives this function as a black box against seeded fixtures.
check_root() {
  python3 - "$1" <<'PY'
import os
import re
import sys

root = sys.argv[1]
requirements = os.path.join(root, "docs/requirements.md")
ID = r"(?:ARC|APP|ENR|MED)-[0-9]{3}[A-Z]?"
# Spelled in two parts so process-check, which reads this script for tags, finds none here.
TAG = "Valid" + "ates:"


def fail(message):
    print(f"requirements authority check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


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

if report_matches(lines, r"`Proposed`|\[(?:Proposed|Planned)\]|^\s*Status:\s*Proposed"):
    fail("docs/requirements.md must not contain Proposed requirements or define Proposed as a status")
if report_matches(lines, r"^#+\s.*\b(?:Future|Planned|Backlog)\b"):
    fail("docs/requirements.md must not contain a future-requirement section (future work lives in GitHub issues)")
if report_matches(lines, r"^#+\s+(?:Process|Tooling|Testing)\b"):
    fail("docs/requirements.md must not contain Process/Tooling/Testing sections (process rules live in CLAUDE.md)")

# Items: `- **<ID>** ...` and the contiguous lines under it, up to a blank line, a heading or
# the next `- **` item (the same block process-check reads).
items = []
for index, line in enumerate(lines):
    m = re.match(r"^\s*[-*]\s+\*\*([^*]+)\*\*", line)
    if not m:
        continue
    block = [line]
    for follow in lines[index + 1:]:
        if re.match(r"^\s*$|^#|^\s*[-*]\s+\*\*", follow):
            break
        block.append(follow)
    items.append((m.group(1), index + 1, block))

if not items:
    fail("docs/requirements.md declares no requirements")

missing = False
for requirement_id, number, block in items:
    where = f"requirement {requirement_id} (docs/requirements.md:{number})"
    if not re.fullmatch(ID, requirement_id):
        fail(f"{where} has unrecognized ID '{requirement_id}'")
    text = [b for b in block if not re.match(r"^\s*(Implemented in|Not covered by tests|unverified):", b)]
    body = " ".join(text)
    if re.search(r"animatingDifferences|NSAnimationContext|PRAGMA|COALESCE|INDEXED BY|plan [0-9]{4}|n ≥|k=", body):
        fail(f"{where} contains implementation token")
    if re.search(r"[0-9]+ ?ms\b", " ".join(block)):
        fail(f"{where} contains bare timing constant")
    if re.search(r"\bmanual:", " ".join(block)):
        fail(f"{where} uses manual: verification (not machine-checked)")
    if not any(re.match(r"^\s*Example:\s*\S", b) for b in block):
        fail(f"{where} has no Example: line")
    implemented = [b for b in block if re.match(r"^\s*Implemented in:", b)]
    if len(implemented) != 1:
        fail(f"{where} needs exactly one Implemented in: line")
    paths = re.findall(r"`([^`]+)`", implemented[0])
    if not paths:
        fail(f"{where} Implemented in: names no backticked path")
    for path in paths:
        if "*" in path:
            continue
        if not os.path.exists(os.path.join(root, path.strip())):
            print(f"missing path cited in requirements.md: {path} ({requirement_id})", file=sys.stderr)
            missing = True
if missing:
    fail("one or more Implemented in: paths do not exist on disk")

# Tags in the Swift tests. A tag line sits directly above the test it marks: above its doc
# comment and any `// swiftlint:disable:next`, which must stay attached to the test, then its
# attribute block (@Test, @Suite, @MainActor, a multi-line @Test(arguments: ...)) or the
# declaration itself. The test it marks must be able to fail.
DECLARATION = re.compile(
    r"^\s*(?:(?:private|fileprivate|internal|public|static|nonisolated|final|override|mutating|async)\s+)*"
    r"(?:func|struct|final\s+class|class|enum|extension|actor)\s+([A-Za-z_][\w.]*)"
)
ASSERTION_TOKENS = ("#expect(", "#require(", "Issue.record(")


def strip_attributes(line):
    """A line without its leading attributes (`@Test`, `@Suite(.serialized)`, `@MainActor`)."""
    while True:
        stripped = re.sub(r"^@\w+(?:\([^()]*\))?\s*", "", line)
        if stripped == line:
            return line
        line = stripped


def body_of(source, start):
    """The text inside the braces of the declaration that starts at offset start."""
    opening = source.find("{", start)
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    return None


def can_fail(body):
    body = re.sub(r"#expect\s*\(\s*true\b[^\n]*\)", "", body)
    return any(token in body for token in ASSERTION_TOKENS) or re.search(
        r"\b(?:assert[A-Za-z_]*|waitFor[A-Za-z_]*|verify[A-Za-z_]*)\s*\(", body
    ) is not None


tests_dir = os.path.join(root, "OtosTests")
swift_files = []
for directory, _, names in os.walk(tests_dir):
    swift_files += [os.path.join(directory, n) for n in names if n.endswith(".swift")]
tag_line = re.compile(r"^\s*//\s*" + TAG)
tags = 0
for path in sorted(swift_files):
    relative = os.path.relpath(path, root)
    source = open(path, encoding="utf-8").read()
    source_lines = source.split("\n")
    offsets, offset = [], 0
    for text in source_lines:
        offsets.append(offset)
        offset += len(text) + 1
    for index, text in enumerate(source_lines):
        if not tag_line.match(text):
            continue
        where = f"{relative}:{index + 1}"
        tags += 1
        following = index + 1
        while following < len(source_lines) and re.match(
            r"\s*(///|// swiftlint:disable:next)", source_lines[following]
        ):
            following += 1
        depth = 0
        attributes = []
        declaration = None
        while following < len(source_lines):
            line = source_lines[following].strip()
            if depth == 0:
                declaration = DECLARATION.match(strip_attributes(line))
                if declaration or not line.startswith("@"):
                    break
            attributes.append(line)
            depth += line.count("(") + line.count("[") - line.count(")") - line.count("]")
            following += 1
        if declaration is None:
            fail(f"{where}: a {TAG} tag must sit directly above a test's attributes or declaration")
        attributes.append(source_lines[following].strip())
        if re.search(r"\bfunc\s", strip_attributes(source_lines[following])) and not any(
            re.match(r"@(?:Test|MainActor)\b", a) for a in attributes
        ):
            fail(f"{where}: the tagged function {declaration.group(1)} is not a test")
        body = body_of(source, offsets[following])
        if body is None:
            fail(f"{where}: tagged declaration {declaration.group(1)} has no terminated body")
        if not can_fail(body):
            fail(f"{where}: tagged test {declaration.group(1)} has no failing assertion")

print(f"requirements authority check: clean ({len(items)} requirements, {tags} tagged tests)")
PY
}

self_test() {
  echo "requirements authority check self-test: start"
  # Spelled in two parts so process-check, which reads this script for tags, finds none here.
  local tag="// Valid""ates: ARC-999"

  # A valid fixture: one verified and one unverified item, the implementation file, and a test
  # file whose tags sit above a plain @Test, a multi-line @Test(arguments:), an @MainActor
  # function, a @Suite, and a test whose doc comment and swiftlint:disable:next sit between
  # the tag and its @Test. Each failing case below starts from it and breaks one rule.
  make_valid() {
    local t="$1"
    mkdir -p "$t/docs" "$t/OtosKit" "$t/OtosTests"
    touch "$t/OtosKit/Foo.swift"
    cat > "$t/docs/requirements.md" <<'DOC'
# Otos Requirements

## Architecture And System

- **ARC-999** The catalog shall keep one row per file. [verified]
  - When a file is renamed, the catalog shall move its row.
  Example: Given a file, the catalog holds one row for it.
  Implemented in: `OtosKit/Foo.swift`

- **ARC-002A** The grid shall show each row. [verified]
  Example: Given a row, the grid shows it.
  Implemented in: `OtosKit/Foo.swift`
  Not covered by tests: the drawn tile, checked in the running app

- **APP-998** Otos shall say what it does.
  Example: Given work, the window says so.
  Implemented in: `OtosKit/Foo.swift`
  unverified: the wording is read from code, not seen in the app
DOC
    {
      echo 'import Testing'
      echo "$tag"
      echo '@Suite struct FooTests {'
      echo "    $tag"
      echo '    @Test func keepsOneRow() { #expect(1 == 1) }'
      echo "    $tag"
      echo '    @Test(arguments: ['
      echo '        (1, 2),'
      echo '    ])'
      echo '    func addsUp(a: Int, b: Int) { #expect(a < b) }'
      echo "    $tag"
      echo '    @MainActor'
      echo '    static func scenario() throws { try #require(true == true) }'
      echo "    $tag"
      echo '    /// A doc comment and a lint exception stay attached to the test below the tag.'
      echo '    // swiftlint:disable:next cyclomatic_complexity'
      echo '    @Test func documented() { #expect(2 == 2) }'
      echo '}'
    } > "$t/OtosTests/FooTests.swift"
  }

  expect_fail() {
    local desc="$1" t="$2"
    if (check_root "$t") >/dev/null 2>&1; then
      echo "self-test failed: $desc should have failed but passed" >&2
      exit 1
    fi
    echo "self-test ok: $desc correctly failed"
  }

  expect_pass() {
    local desc="$1" t="$2"
    if ! (check_root "$t") >/dev/null 2>&1; then
      echo "self-test failed: $desc should have passed but failed" >&2
      (check_root "$t") 2>&1 | head -n 20 >&2
      exit 1
    fi
    echo "self-test ok: $desc correctly passed"
  }

  tmpBase=$(mktemp -d)
  trap 'rm -rf "$tmpBase"' EXIT
  n=0
  # fixture: a fresh valid tree, echoed as its path.
  fixture() { n=$((n + 1)); local t="$tmpBase/t$n"; make_valid "$t"; echo "$t"; }
  # add_line FILE LINE: append a line to a fixture file.
  add_line() { printf '%s\n' "$2" >> "$1"; }

  t=$(fixture)
  expect_pass "valid registry and tags" "$t"

  t=$(fixture)
  longReq=$(printf 'a%.0s' {1..2000})"∪∪"
  printf '\n- **ARC-997** The catalog shall %s. [verified]\n  Example: Given %s.\n  Implemented in: `OtosKit/Foo.swift`\n' "$longReq" "$longReq" >> "$t/docs/requirements.md"
  expect_pass "long multibyte item (no length cap)" "$t"

  t=$(fixture)
  add_line "$t/docs/requirements.md" '  Status: Proposed'
  expect_fail "Proposed status" "$t"

  t=$(fixture)
  add_line "$t/docs/requirements.md" '## Future Requirements'
  expect_fail "future-requirement section" "$t"

  t=$(fixture)
  add_line "$t/docs/requirements.md" '## Process'
  expect_fail "process section" "$t"

  t=$(fixture)
  printf '\n- **BAD-001** The catalog shall exist.\n  Example: x.\n  Implemented in: `OtosKit/Foo.swift`\n  unverified: none yet\n' >> "$t/docs/requirements.md"
  expect_fail "unrecognized ID" "$t"

  t=$(fixture)
  sed -i.bak 's/keep one row per file/keep one row per file with animatingDifferences/' "$t/docs/requirements.md"
  expect_fail "implementation token" "$t"

  t=$(fixture)
  sed -i.bak 's/move its row/move its row within 250 ms/' "$t/docs/requirements.md"
  expect_fail "bare timing constant" "$t"

  t=$(fixture)
  sed -i.bak 's/unverified: the wording.*/manual: read the window/' "$t/docs/requirements.md"
  expect_fail "manual: verification" "$t"

  t=$(fixture)
  sed -i.bak '/Given a file, the catalog/d' "$t/docs/requirements.md"
  expect_fail "missing Example: line" "$t"

  t=$(fixture)
  python3 -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("  Implemented in: `OtosKit/Foo.swift`\n", "", 1))' "$t/docs/requirements.md"
  expect_fail "missing Implemented in: line" "$t"

  t=$(fixture)
  sed -i.bak 's#`OtosKit/Foo.swift`#`OtosKit/NoSuch.swift`#' "$t/docs/requirements.md"
  expect_fail "missing Implemented in: path" "$t"

  t=$(fixture)
  { echo "$tag"; echo 'let notATest = 1'; } >> "$t/OtosTests/FooTests.swift"
  expect_fail "tag not above a test" "$t"

  t=$(fixture)
  { echo "$tag"; echo '@Test func neverFails() { let x = 1; _ = x }'; } >> "$t/OtosTests/FooTests.swift"
  expect_fail "tagged test with no failing assertion" "$t"

  t=$(fixture)
  { echo "$tag"; echo '@Test func tautology() { #expect(true, "always") }'; } >> "$t/OtosTests/FooTests.swift"
  expect_fail "tagged tautological test" "$t"

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
