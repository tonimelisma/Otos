#!/usr/bin/env bash
# script/check.sh on Taylor's Mac from a Claude Code cloud session, through Latchkey's
# shell_run (AGENTS.md, "Cloud Sessions"). The session clones its pushed branch into
# Latchkey's scratch folder and runs this from that clone:
#
#   cd "$LATCHKEY_SCRATCH" && git clone -q --reference ~/Development/Otos --branch <branch> \
#     https://github.com/tonimelisma/Otos.git o && o/script/latchkey-check.sh [--only <Suite>]...; \
#     rc=$?; rm -rf o; exit $rc
#
# Arguments go to script/check.sh. The clone is removed by the command, not here: bash reads
# a script as it runs, so a script must not delete itself.
#
# What it adds around check.sh, each for a fact of Latchkey's fence:
# - xcodebuild with its task sandbox off. macOS cannot start a sandbox inside the fence, and
#   Latchkey's own xcodebuild wrapper turns off only SwiftPM's two, so every
#   CoreMLModelCompile failed with `sandbox_apply: Operation not permitted`. This drops out
#   once Latchkey's wrapper passes DISABLE_TASK_SANDBOXING=YES.
# - the primary checkout's resolved packages, as an APFS clone: a plain clone is no
#   worktree, so script/lib/xcode.sh does not seed them, and resolving GRDB's submodule
#   over HTTPS has hung.
# - Xcode's asset-catalog daemon, ibtoold, stopped at the end when this run started it. It
#   outlives the job under launchd and keeps the job's fence, so every later build on the
#   Mac, Latchkey's or not, failed to write its asset catalog (2026-11-21).
# - SwiftLint's warnings left out of the output: hundreds of kilobytes per run, more than a
#   shell_check answer holds.
set -uo pipefail

[[ -n "${LATCHKEY_SCRATCH:-}" ]] || { echo "latchkey-check: run this inside a Latchkey shell_run job" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

wrapper_dir="$LATCHKEY_SCRATCH/bin"
mkdir -p "$wrapper_dir"
cat > "$wrapper_dir/xcodebuild" <<'SH'
#!/bin/sh
exec /usr/bin/xcodebuild -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES DISABLE_TASK_SANDBOXING=YES "$@"
SH
chmod +x "$wrapper_dir/xcodebuild"
export PATH="$wrapper_dir:$PATH"

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

daemons_before=" $(pgrep -x ibtoold | tr '\n' ' ') "
"$ROOT_DIR/script/check.sh" "$@" 2>&1 | grep --line-buffered -vE ': warning: |^Linting '
status="${PIPESTATUS[0]}"
for pid in $(pgrep -x ibtoold); do
  [[ "$daemons_before" == *" $pid "* ]] && continue
  kill "$pid" 2>/dev/null && echo "op=latchkey-check.teardown phase=stopped process=ibtoold pid=$pid"
done
exit "$status"
