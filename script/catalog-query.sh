#!/usr/bin/env bash
set -euo pipefail

# A catalog is named explicitly, never defaulted: the installed app's catalog is the owner's
# production data, which no check or diagnostic reads (owner, 2026-11-15).
usage() {
  echo "usage: script/catalog-query.sh name-vs-capture <catalog.sqlite>" >&2
  exit 2
}

[[ "${1:-}" == "name-vs-capture" && -n "${2:-}" ]] || usage
CATALOG_DB="$2"

if [[ ! -f "$CATALOG_DB" ]]; then
  echo "catalog database not found: $CATALOG_DB" >&2
  exit 1
fi

exec sqlite3 -readonly -header -column "$CATALOG_DB" <<'SQL'
SELECT library_root_id, relative_path, capture_wall_compact
  FROM media_asset
 WHERE import_batch_unix_ms IS NOT NULL
   AND capture_wall_compact IS NOT NULL
   AND relative_path GLOB '*/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].*'
   AND CAST(
         substr(replace(relative_path, rtrim(relative_path, replace(relative_path, '/', '')), ''), 1, 8)
         || substr(replace(relative_path, rtrim(relative_path, replace(relative_path, '/', '')), ''), 10, 6)
         AS INTEGER
       ) <> capture_wall_compact;
SQL
