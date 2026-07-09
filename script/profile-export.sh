#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  script/profile-export.sh <trace.trace> [--toc|--xpath <xpath>]

Thin wrapper over `xctrace export` so agents can parse Instruments traces
with one command. Default is --toc.
EOF
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 2
fi

TRACE="$1"
shift

if [[ ! -e "$TRACE" ]]; then
  echo "Trace not found: $TRACE" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  xcrun xctrace export --input "$TRACE" --toc
  exit 0
fi

case "$1" in
  --toc)
    xcrun xctrace export --input "$TRACE" --toc
    ;;
  --xpath)
    shift
    xpath="${1:-}"
    [[ -n "$xpath" ]] || { echo "Missing --xpath value" >&2; exit 2; }
    xcrun xctrace export --input "$TRACE" --xpath "$xpath"
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    exit 2
    ;;
esac
