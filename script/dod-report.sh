#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${BASE_REF:-origin/main}"

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

mark_for() {
  case "${1:-red}" in
    green|GREEN|ok|OK|pass|PASS|yes|YES)
      printf '✅'
      ;;
    red|RED|fail|FAIL|no|NO|blocker|BLOCKER)
      printf '❌'
      ;;
    *)
      printf '❌'
      ;;
  esac
}

row() {
  local status="$1"
  local label="$2"
  local text="$3"
  printf '%s **%s:** %s\n' "$(mark_for "$status")" "$label" "$text"
}

row_env() {
  local status_var="$1"
  local label="$2"
  local text_var="$3"
  local status="${!status_var:-red}"
  local text="${!text_var:-<missing final DoD description>}"
  row "$status" "$label" "$text"
}

section() {
  printf '\n## %s\n' "$1"
}

branch="$(git_value branch --show-current)"
head_full="$(git_value rev-parse HEAD)"
head_short="$(git_value rev-parse --short HEAD)"
upstream_ref="$(git_value rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
upstream_full="$(git_value rev-parse '@{u}')"
worktree_status="$(git -C "$ROOT_DIR" status --short)"

push_status="red"
push_text="No upstream is configured for ${branch:-<unknown branch>}."
if [[ -n "$upstream_ref" && -n "$head_full" && "$head_full" == "$upstream_full" ]]; then
  push_status="green"
  push_text="Branch ${branch:-<unknown branch>} is pushed to $upstream_ref at ${head_short:-<unknown>}."
elif [[ -n "$upstream_ref" ]]; then
  push_text="Branch ${branch:-<unknown branch>} has upstream $upstream_ref, but local HEAD differs from upstream."
fi

tree_status="red"
tree_text="Working tree is dirty."
if [[ -z "$worktree_status" ]]; then
  tree_status="green"
  tree_text="Working tree is clean."
fi

section "Final DoD Report"
printf 'Repo: %s\n' "$ROOT_DIR"
printf 'Branch: %s\n' "${branch:-<unknown>}"
printf 'Head: %s\n' "${head_short:-<unknown>}"
printf 'Base ref for changed-file evidence: %s\n' "$BASE_REF"
if [[ -n "${DOD_PR:-}" ]]; then
  printf 'PR: %s\n' "$DOD_PR"
fi
printf '\nThis is the single final DoD report for the increment. Do not use this output as a review handoff, partial, pre-merge, or ready-for-review report.\n'
printf 'Post this full report on the PR and send the same full report to the user — never a summary with a link.\n'

section "Final Questions"
row_env DOD_DONE_STATUS "What was done" DOD_DONE
row_env DOD_NOT_DONE_STATUS "What planned work was not done" DOD_NOT_DONE
row_env DOD_DESIGN_STATUS "What design decisions were made" DOD_DESIGN
row_env DOD_DOCS_STATUS "What requirements, ADRs, and docs changed" DOD_DOCS
row_env DOD_VERIFICATION_STATUS "What verification ran" DOD_VERIFICATION
row_env DOD_CI_STATUS "What remote CI reported" DOD_CI
row_env DOD_INSTRUMENTATION_STATUS "What instrumentation or performance evidence exists" DOD_INSTRUMENTATION
row_env DOD_SMELLS_STATUS "What code smells remain" DOD_SMELLS
row_env DOD_PRIVACY_STATUS "What privacy and media-originals review found" DOD_PRIVACY
row_env DOD_RISKS_STATUS "What risks or follow-up remain" DOD_RISKS
row_env DOD_AFTER_DOD_STATUS "What non-blocking after-DoD user verification remains" DOD_AFTER_DOD
row "$push_status" "Branch push" "$push_text"
row_env DOD_MERGE_STATUS "PR merge" DOD_MERGE
row_env DOD_LOCAL_MAIN_STATUS "Local main update" DOD_LOCAL_MAIN
row_env DOD_POST_MERGE_STATUS "Post-merge verification" DOD_POST_MERGE
row_env DOD_BRANCH_CLEANUP_STATUS "Branch cleanup" DOD_BRANCH_CLEANUP
row_env DOD_WORKTREE_CLEANUP_STATUS "Worktree cleanup" DOD_WORKTREE_CLEANUP
row_env DOD_STASH_STATUS "Increment stash cleanup" DOD_STASH
row_env DOD_STALE_STATUS "Stale branch and worktree review" DOD_STALE
row "$tree_status" "Final working tree" "$tree_text"

section "Changed Files"
files="$(changed_files)"
if [[ -z "$files" ]]; then
  printf 'No files differ from %s.\n' "$BASE_REF"
else
  printf '%s\n' "$files"
fi
