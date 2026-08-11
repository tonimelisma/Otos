#!/usr/bin/env bash
# Removes every net.melisma.OtosTests.* preference domain. These are test-run
# residue (ADR 0020); none is production state. Never touches
# net.melisma.Otos.plist — the production domain — which is why the glob is
# anchored to the `.OtosTests.` infix, not a prefix match on `net.melisma.Otos`.
set -euo pipefail
prefs="$HOME/Library/Preferences"
count=0
for f in "$prefs"/net.melisma.OtosTests.*.plist; do
  [[ -e "$f" ]] || continue
  rm -f "$f"
  count=$((count + 1))
done
echo "Removed $count test preference domain(s)."
# cfprefsd caches domains; without this it can re-flush a deleted file.
killall -u "$USER" cfprefsd 2>/dev/null || true
