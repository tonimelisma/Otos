#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/build/production-data-check"
STATE_FILE="$STATE_DIR/state.txt"
CATALOG_PATH="$HOME/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite"
PREFS_APP_PLIST="$HOME/Library/Preferences/net.melisma.Otos.plist"
PREFS_DIR="$HOME/Library/Preferences"

usage() {
  cat <<'EOF'
Usage:
  script/check-production-data-untouched.sh --before
  script/check-production-data-untouched.sh --after

Guards the invariant ADR 0020 exists for: a test run must never touch the
user's production catalog or production preferences, and must never leave
behind a test preference domain carrying real values.

--before records the production catalog's and net.melisma.Otos.plist's
mtime+size (or "absent"), plus the current set of other net.melisma.Otos*
preference-file names, to an ignored scratch file.

--after re-reads both and fails if the catalog or net.melisma.Otos.plist
changed at all, or if any *new* preference-domain file appeared that is not
empty. A new *empty* ({}) domain file is not a failure: OtosTests/
TemporaryDefaults.swift documents, with measurement, that macOS's cfprefsd can
leave an empty stub behind under concurrent test execution even after
explicit cleanup — that is not a data leak, and this check must not flake on
it. A domain with real keys in it is a genuine regression and fails loudly,
naming the file.
EOF
}

file_state() {
  local path="$1"
  if [[ -f "$path" ]]; then
    stat -f '%m %z' "$path"
  else
    echo "absent"
  fi
}

# True (exit 0) when the plist at $1 has at least one key — i.e. carries real
# data, not just an empty {} stub. Converts to JSON rather than counting bytes
# because empty-plist byte size is a serialization detail, not a stable
# contract; key count is what "has data" actually means.
domain_has_data() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    # Already gone by the time we checked (e.g. its own later cleanup ran) —
    # nothing to flag.
    return 1
  fi
  local json
  json="$(plutil -convert json -o - "$path" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$json" && "$json" != "{}" ]]
}

other_domain_names() {
  # Use -exec basename to handle paths with spaces (xargs -n1 basename splits on
  # whitespace). Each find result is passed as a single argument to basename.
  find "$PREFS_DIR" -maxdepth 1 -name 'net.melisma.Otos*' ! -name 'net.melisma.Otos.plist' -exec basename {} \; 2>/dev/null \
    | LC_ALL=C sort
}

# Absolute: no OtosTests domain may carry real values, whether or not this run
# created it. The --before/--after diff catches regressions introduced by this
# run; this catches the 111 data-carrying domains that accumulated before the
# diff check existed.
assert_no_data_carrying_test_domains() {
  local offenders=()
  for f in "$PREFS_DIR"/net.melisma.OtosTests.*.plist; do
    [[ -e "$f" ]] || continue
    if domain_has_data "$f"; then offenders+=("$f"); fi
  done
  if (( ${#offenders[@]} > 0 )); then
    echo "FAIL: ${#offenders[@]} test preference domain(s) carry real values." >&2
    printf '  %s\n' "${offenders[@]}" >&2
    echo "Run script/purge-test-preference-domains.sh, then re-run." >&2
    return 1
  fi
}

record_before() {
  mkdir -p "$STATE_DIR"
  {
    echo "catalog: $(file_state "$CATALOG_PATH")"
    echo "app_plist: $(file_state "$PREFS_APP_PLIST")"
    echo "---other-domains---"
    other_domain_names
  } > "$STATE_FILE"
  # Absolute check also runs at --before so a pre-existing leak fails fast
  # before blaming the current change.
  assert_no_data_carrying_test_domains || exit 1
}

check_after() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No --before state recorded at $STATE_FILE; run --before first." >&2
    exit 2
  fi

  local before_catalog before_app_plist
  before_catalog="$(sed -n 's/^catalog: //p' "$STATE_FILE")"
  before_app_plist="$(sed -n 's/^app_plist: //p' "$STATE_FILE")"
  local before_other
  before_other="$(sed -n '/^---other-domains---$/,$p' "$STATE_FILE" | tail -n +2)"

  local failed=0

  local after_catalog
  after_catalog="$(file_state "$CATALOG_PATH")"
  if [[ "$after_catalog" != "$before_catalog" ]]; then
    echo "FAIL: production catalog changed during this run." >&2
    echo "  path:   $CATALOG_PATH" >&2
    echo "  before: $before_catalog" >&2
    echo "  after:  $after_catalog" >&2
    failed=1
  fi

  local after_app_plist
  after_app_plist="$(file_state "$PREFS_APP_PLIST")"
  if [[ "$after_app_plist" != "$before_app_plist" ]]; then
    echo "FAIL: production preferences changed during this run." >&2
    echo "  path:   $PREFS_APP_PLIST" >&2
    echo "  before: $before_app_plist" >&2
    echo "  after:  $after_app_plist" >&2
    failed=1
  fi

  local after_other new_names
  after_other="$(other_domain_names)"
  # Use printf to avoid echo's interpretation and filter empty lines so an
  # empty state (no domains) does not inject a spurious empty entry via comm.
  new_names="$(comm -13 <(printf "%s\n" "$before_other" | LC_ALL=C sort | grep -v '^$' || true) <(printf "%s\n" "$after_other" | LC_ALL=C sort | grep -v '^$' || true) 2>/dev/null || true)"
  if [[ -n "$new_names" ]]; then
    local leaked=()
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if domain_has_data "$PREFS_DIR/$name"; then
        leaked+=("$name")
      fi
    done <<< "$new_names"
    if (( ${#leaked[@]} > 0 )); then
      echo "FAIL: test run left behind preference domain(s) carrying real values:" >&2
      for name in "${leaked[@]}"; do
        echo "  $PREFS_DIR/$name" >&2
      done
      failed=1
    fi
  fi

  # Absolute check: catches any data-carrying domain even if it predates --before.
  if ! assert_no_data_carrying_test_domains; then
    failed=1
  fi

  if (( failed != 0 )); then
    exit 1
  fi
  echo "production-data-untouched: clean"
}

main() {
  local action="${1:-}"
  case "$action" in
    --before)
      record_before
      ;;
    --after)
      check_after
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
