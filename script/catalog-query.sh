#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: script/catalog-query.sh name-vs-capture [catalog.sqlite]" >&2
  exit 2
}

[[ "${1:-}" == "name-vs-capture" ]] || usage
CATALOG_DB="${2:-${OTOS_CATALOG_DB:-/Users/example/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite}}"

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
