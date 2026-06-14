#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/script/requirements-authority-check.sh"
"$ROOT_DIR/script/lint.sh"
"$ROOT_DIR/script/build.sh"
"$ROOT_DIR/script/test.sh"
