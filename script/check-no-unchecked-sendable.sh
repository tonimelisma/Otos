#!/usr/bin/env bash
# ARC-042: zero `@unchecked Sendable` in app and test sources. This exists because
# the requirement was verified by the string `manual:` for its whole life and drifted
# from 0 to 14 without one failing gate (plan 0072 §1.4).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if hits="$(grep -rn '@unchecked Sendable' "$ROOT_DIR/Otos" "$ROOT_DIR/OtosTests" --include='*.swift')"; then
  echo "FAIL: ARC-042 forbids @unchecked Sendable. Found:" >&2
  echo "$hits" >&2
  echo "Use Mutex (Synchronization) or an actor. See docs/plans/0072-*.md." >&2
  exit 1
fi
echo "ARC-042 OK: no @unchecked Sendable."
