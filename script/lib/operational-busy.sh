#!/usr/bin/env bash

# Returns success when the catalog proves any import or reorganization is in
# flight. A missing catalog is idle; inability to inspect an existing catalog
# is busy because smoke cleanup must never terminate work on uncertain evidence.
has_active_operational_work() {
  local catalog_db="$1"
  [[ -f "$catalog_db" ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 0

  local output rc
  output="$(sqlite3 -readonly "$catalog_db" \
    "SELECT source_root_path FROM active_file_operation UNION ALL SELECT library_root_path FROM active_reorganization_component LIMIT 1;" \
    2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    return 0
  fi
  [[ -n "$output" ]] || return 1
  printf '%s\n' "$output"
}

is_import_active() {
  has_active_operational_work "$@"
}
