#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${BASE_REF:-origin/main}"

section() {
  printf '\n## %s\n' "$1"
}

value() {
  printf '%s: %s\n' "$1" "$2"
}

git_value() {
  git -C "$ROOT_DIR" "$@" 2>/dev/null || true
}

changed_files() {
  if git -C "$ROOT_DIR" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    git -C "$ROOT_DIR" diff --name-only "$BASE_REF"...HEAD
  else
    git -C "$ROOT_DIR" diff --name-only HEAD
  fi
}

section "Increment"
value "repo" "$ROOT_DIR"
value "branch" "$(git_value branch --show-current)"
value "head" "$(git_value rev-parse --short HEAD)"
value "base-ref" "$BASE_REF"
value "worktree" "$(pwd)"

section "Working Tree"
status="$(git -C "$ROOT_DIR" status --short)"
if [[ -z "$status" ]]; then
  value "status" "clean"
else
  value "status" "dirty"
  printf '%s\n' "$status"
fi

section "Changed Files"
files="$(changed_files)"
if [[ -z "$files" ]]; then
  value "changed-files" "none"
else
  printf '%s\n' "$files"
fi

section "Toolchain"
developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
value "xcode-select" "${developer_dir:-<none>}"
if [[ -n "$developer_dir" && -x "$developer_dir/usr/bin/xcodebuild" ]]; then
  "$developer_dir/usr/bin/xcodebuild" -version | sed 's/^/xcodebuild: /'
else
  value "xcodebuild" "unavailable"
fi

section "Local Verification Evidence"
value "script/verify.sh" "${DOD_VERIFY_EVIDENCE:-<paste PR summary or run script/verify.sh>}"
value "focused-tests" "${DOD_FOCUSED_TESTS:-<not supplied>}"

section "CI Evidence"
value "github-actions" "${DOD_CI_EVIDENCE:-<paste PR check status or quota exhaustion evidence>}"
value "quota-waiver" "${DOD_CI_QUOTA_WAIVER:-not claimed}"

section "Docs And Requirements"
value "requirements" "${DOD_REQUIREMENTS:-<list requirement IDs updated or not applicable>}"
value "spec" "${DOD_SPEC:-<link spec or not applicable>}"
value "adr" "${DOD_ADR:-<link ADRs or not applicable>}"

section "Performance And Instrumentation"
value "logs" "${DOD_LOG_EVIDENCE:-<not applicable or not supplied>}"
value "profiles" "${DOD_PROFILE_EVIDENCE:-<not applicable or not supplied>}"
value "worst-span-summary" "${DOD_PERFORMANCE_SUMMARY:-<not applicable or not supplied>}"

section "Code Smells Observed"
value "smells" "${DOD_CODE_SMELLS:-<required: list smells observed, or None observed>}"
value "outcome" "${DOD_CODE_SMELL_OUTCOME:-<required when smells were observed>}"

section "Privacy And Media"
value "privacy-impact" "${DOD_PRIVACY_IMPACT:-<not supplied>}"
value "media-impact" "${DOD_MEDIA_IMPACT:-<not supplied>}"

section "Risks And Follow-Up"
value "unresolved-risks" "${DOD_RISKS:-<none supplied>}"
value "follow-up" "${DOD_FOLLOW_UP:-<none supplied>}"

section "Increment Closure"
value "merge-status" "${DOD_MERGE_STATUS:-<not merged or not supplied>}"
value "local-main-updated" "${DOD_LOCAL_MAIN_UPDATED:-<not supplied>}"
value "post-merge-verification" "${DOD_POST_MERGE_VERIFY:-<not applicable or not supplied>}"
value "local-branch-cleanup" "${DOD_LOCAL_BRANCH_CLEANUP:-<not complete or not supplied>}"
value "remote-branch-cleanup" "${DOD_REMOTE_BRANCH_CLEANUP:-<not complete or not supplied>}"
value "worktree-cleanup" "${DOD_WORKTREE_CLEANUP:-<not applicable or not supplied>}"
value "increment-stashes-cleared" "${DOD_STASH_CLEANUP:-<not applicable or not supplied>}"
value "stale-branches-worktrees-reviewed" "${DOD_STALE_REVIEW:-<not supplied>}"
value "next-increment-ready" "${DOD_NEXT_INCREMENT_READY:-<not supplied>}"
