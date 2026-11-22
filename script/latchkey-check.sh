#!/usr/bin/env bash
# script/check.sh on Taylor's Mac from a Claude Code cloud session, through Latchkey's
# shell_run with `uses: ["open"]` (AGENTS.md, "Cloud Sessions"). The session clones its
# pushed branch into Latchkey's scratch folder and runs this from that clone:
#
#   cd "$LATCHKEY_SCRATCH" && git clone -q --reference ~/Development/Otos --branch <branch> \
#     https://github.com/tonimelisma/Otos.git o && o/script/latchkey-check.sh [--only <Suite>]...; \
#     rc=$?; rm -rf o; exit $rc
#
# Arguments go to script/check.sh. The clone is removed by the command, not here: bash reads
# a script as it runs, so a script must not delete itself.
#
# Latchkey owns what its fence needs from Xcode: its xcodebuild wrapper and Xcode settings
# turn off xcodebuild's own sandboxes, each job gets its own ibtoold, stopped with the job,
# and the tests of `xcodebuild test-without-building` run outside the fence through
# Latchkey's launcher. This adds only what is Otos's:
# - the primary checkout's resolved packages, as an APFS clone: a plain clone is no
#   worktree, so script/lib/xcode.sh does not seed them, and resolving GRDB's submodule
#   over HTTPS has hung.
# - SwiftLint's warnings left out of the output: hundreds of kilobytes per run, more than a
#   shell_check answer holds.
set -uo pipefail

[[ -n "${LATCHKEY_SCRATCH:-}" ]] || { echo "latchkey-check: run this inside a Latchkey shell_run job" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The clone borrows the primary checkout's objects (`--reference`), so its alternates file
# names that checkout's .git/objects.
alternates="$ROOT_DIR/.git/objects/info/alternates"
if [[ -f "$alternates" && ! -d "$ROOT_DIR/build/DerivedData/SourcePackages/checkouts" ]]; then
  primary="$(dirname "$(dirname "$(head -n 1 "$alternates")")")"
  if [[ -d "$primary/build/DerivedData/SourcePackages/checkouts" ]]; then
    mkdir -p "$ROOT_DIR/build/DerivedData"
    /bin/cp -cR "$primary/build/DerivedData/SourcePackages" "$ROOT_DIR/build/DerivedData/" \
      && echo "op=latchkey-check.packages phase=seeded from=$primary"
  fi
fi

"$ROOT_DIR/script/check.sh" "$@" 2>&1 | grep --line-buffered -vE ': warning: |^Linting '
exit "${PIPESTATUS[0]}"
