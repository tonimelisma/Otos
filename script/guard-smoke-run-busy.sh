#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT_DIR/script/lib/operational-busy.sh"
self_test() {
  command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is required for smoke predicate self-test" >&2; return 1; }
  local d db corrupt fake_path
  d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN; db="$d/catalog.sqlite"
  sqlite3 "$db" 'CREATE TABLE active_file_operation(source_root_path TEXT, phase TEXT); CREATE TABLE active_reorganization_component(library_root_path TEXT);'
  if has_active_operational_work "$db"; then echo "empty fixture reported busy" >&2; return 1; fi
  sqlite3 "$db" "INSERT INTO active_file_operation VALUES ('$d/root-a', 'abandoned');"
  if has_active_operational_work "$db"; then echo "abandoned-cleanup fixture reported busy" >&2; return 1; fi
  sqlite3 "$db" "INSERT INTO active_file_operation VALUES ('$d/root-b', 'copying');"
  has_active_operational_work "$db" || { echo "active import fixture reported idle" >&2; return 1; }
  sqlite3 "$db" 'DELETE FROM active_file_operation; INSERT INTO active_reorganization_component VALUES ("root-c");'
  has_active_operational_work "$db" || { echo "active reorganization fixture reported idle" >&2; return 1; }
  corrupt="$d/corrupt.sqlite"; printf 'not sqlite' > "$corrupt"
  has_active_operational_work "$corrupt" || { echo "corrupt fixture reported idle" >&2; return 1; }
  # A PATH assignment in a subshell, not a `PATH=… function` prefix: only an assignment clears
  # bash's command hash, so the prefix form still found sqlite3 and tested the failed read.
  fake_path="$d/no-sqlite"; mkdir "$fake_path"; (PATH="$fake_path"; has_active_operational_work "$db") || { echo "missing sqlite3 reported idle" >&2; return 1; }
  is_import_active "$db"; echo "guard-smoke-run-busy self-test: clean oracle"
}
case "${1:-self-test}" in
  self-test) self_test;;
  check) [[ -x "$ROOT_DIR/script/smoke-run.sh" && -f "$ROOT_DIR/script/lib/operational-busy.sh" ]];;
  *) exit 2;;
esac
