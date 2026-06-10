#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "swiftformat is required. Install tools with: brew bundle" >&2
  exit 127
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint is required. Install tools with: brew bundle" >&2
  exit 127
fi

swiftformat --lint "$ROOT_DIR"
swiftlint lint --strict --config "$ROOT_DIR/.swiftlint.yml"
