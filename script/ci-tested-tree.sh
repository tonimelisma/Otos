#!/usr/bin/env bash
# Whether a CI run may skip the build and the tests because the exact tree was already built
# and tested on its pull request (ADR 0062):
#
#   script/ci-tested-tree.sh <event> <ref> <sha>      prints `tested=true` or `tested=false`
#   script/ci-tested-tree.sh self-test
#
# Only a push to main qualifies. The ruleset requires a pull request to be up to date with
# main before it merges, so its squash commit's tree is its head's tree; the proof is read,
# never assumed: the commit's merged pull request, the two trees compared by hash, and the
# newest `CI gate` check of GitHub Actions on that head, which must have succeeded. Anything
# missing or different prints `tested=false`, and CI runs everything. Needs gh with
# GITHUB_REPOSITORY and a token that reads pull requests and checks.
set -euo pipefail

# The decision, from the facts read: pure, so self-test can hold every case.
#   decide <event> <ref> <pull request head or ""> <commit tree> <head tree> <gate conclusion>
decide() {
  local event="$1" ref="$2" head="$3" tree="$4" head_tree="$5" gate="$6"
  if [[ "$event" != push || "$ref" != refs/heads/main ]]; then
    echo "op=ci.tested result=false reason=notAPushToMain event=$event" >&2
  elif [[ -z "$head" ]]; then
    echo "op=ci.tested result=false reason=noMergedPullRequest" >&2
  elif [[ -z "$tree" || "$tree" != "$head_tree" ]]; then
    echo "op=ci.tested result=false reason=treeDiffers tree=$tree head=$head headTree=$head_tree" >&2
  elif [[ "$gate" != success ]]; then
    echo "op=ci.tested result=false reason=gateNotGreen head=$head gate=${gate:-none}" >&2
  else
    echo "op=ci.tested result=true head=$head tree=$tree" >&2
    echo "tested=true"
    return
  fi
  echo "tested=false"
}

self_test() {
  local failures=0
  expect() {
    local got
    got="$(decide "${@:2:6}" 2>/dev/null)"
    if [[ "$got" != "$8" ]]; then
      echo "FAIL: $1: got '$got', expected '$8'" >&2
      failures=$((failures + 1))
    fi
  }
  expect tested push refs/heads/main h t1 t1 success tested=true
  expect pullRequest pull_request refs/pull/1/merge h t1 t1 success tested=false
  expect schedule schedule refs/heads/main h t1 t1 success tested=false
  expect otherBranch push refs/heads/feature h t1 t1 success tested=false
  expect noPullRequest push refs/heads/main "" t1 t1 success tested=false
  expect treeDiffers push refs/heads/main h t1 t2 success tested=false
  expect noTree push refs/heads/main h "" "" success tested=false
  expect gateFailed push refs/heads/main h t1 t1 failure tested=false
  expect gateMissing push refs/heads/main h t1 t1 "" tested=false
  if (( failures > 0 )); then
    echo "op=ci.tested phase=selfTest outcome=failed failures=$failures" >&2
    exit 1
  fi
  echo "op=ci.tested phase=selfTest outcome=pass cases=9"
}

if [[ "${1:-}" == self-test ]]; then
  self_test
  exit 0
fi
[[ $# == 3 ]] || { echo "usage: script/ci-tested-tree.sh <event> <ref> <sha> | self-test" >&2; exit 2; }
event="$1" ref="$2" sha="$3"
head="" tree="" head_tree="" gate=""
if [[ "$event" == push && "$ref" == refs/heads/main ]]; then
  : "${GITHUB_REPOSITORY:?the repository is needed}"
  head="$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha/pulls" \
    --jq '[.[] | select(.merged_at != null and .base.ref == "main")] | first | .head.sha // ""')"
  if [[ -n "$head" ]]; then
    tree="$(gh api "repos/$GITHUB_REPOSITORY/git/commits/$sha" --jq .tree.sha)"
    head_tree="$(gh api "repos/$GITHUB_REPOSITORY/git/commits/$head" --jq .tree.sha)"
    gate="$(gh api "repos/$GITHUB_REPOSITORY/commits/$head/check-runs?check_name=CI%20gate&per_page=100" \
      --jq '[.check_runs[] | select(.app.slug == "github-actions" and .status == "completed")]
        | if length == 0 then "" else (max_by(.started_at) | .conclusion) end')"
  fi
fi
decide "$event" "$ref" "$head" "$tree" "$head_tree" "$gate"
