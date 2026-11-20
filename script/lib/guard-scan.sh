#!/usr/bin/env bash
# Sourced by every source-scanning guard. A guard names each folder or file it scans
# through `guard_scans` before scanning: a path that does not exist fails the guard,
# because a scan of nothing finds nothing and would report clean. A trial move of the
# sources into another folder (docs/research/2026-11-19-structure-prototypes.md) left
# two guards passing having read no file at all.
guard_scans() {
  local guard="$1" path status=0
  shift
  for path in "$@"; do
    if [[ ! -e "$path" ]]; then
      echo "FAIL: $guard scans $path, which does not exist" >&2
      status=1
    fi
  done
  return "$status"
}
