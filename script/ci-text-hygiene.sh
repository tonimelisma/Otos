#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

usage() {
  cat <<'EOF'
Usage:
  script/ci-text-hygiene.sh check
  script/ci-text-hygiene.sh self-test

Environment for check:
  EVENT_NAME=pull_request|push|workflow_dispatch
  BASE_SHA=<base commit for pull_request or before commit for push>
  HEAD_SHA=<head commit>
EOF
}

all_zero_sha() {
  [[ "$1" =~ ^0+$ ]]
}

require_sha() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    echo "Missing required $name." >&2
    exit 2
  fi
}

changed_files() {
  local base_sha="$1"
  local head_sha="$2"

  git diff --name-only -z --diff-filter=ACMRT "$base_sha" "$head_sha"
}

check_conflict_markers_for_changed_files() {
  local base_sha="$1"
  local head_sha="$2"
  local -a files=()
  local file

  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(changed_files "$base_sha" "$head_sha")

  if (( ${#files[@]} == 0 )); then
    return 0
  fi

  if git grep -n -E '^(<<<<<<<|=======|>>>>>>>)' "$head_sha" -- "${files[@]}"; then
    echo "Conflict marker found." >&2
    exit 1
  fi
}

check_conflict_markers_for_tree() {
  local head_sha="$1"

  if git grep -n -E '^(<<<<<<<|=======|>>>>>>>)' "$head_sha"; then
    echo "Conflict marker found." >&2
    exit 1
  fi
}

check_range() {
  local base_sha="$1"
  local head_sha="$2"

  require_sha BASE_SHA "$base_sha"
  require_sha HEAD_SHA "$head_sha"

  git diff --check "$base_sha" "$head_sha"
  check_conflict_markers_for_changed_files "$base_sha" "$head_sha"
}

check_pull_request_range() {
  local base_sha="$1"
  local head_sha="$2"
  local merge_base

  require_sha BASE_SHA "$base_sha"
  require_sha HEAD_SHA "$head_sha"

  merge_base="$(git merge-base "$base_sha" "$head_sha")"
  check_range "$merge_base" "$head_sha"
}

check_head_tree() {
  local head_sha="$1"

  require_sha HEAD_SHA "$head_sha"

  git diff-tree --check --root -r "$head_sha"
  check_conflict_markers_for_tree "$head_sha"
}

check() {
  local event_name="${EVENT_NAME:-${GITHUB_EVENT_NAME:-workflow_dispatch}}"
  local base_sha="${BASE_SHA:-}"
  local head_sha="${HEAD_SHA:-${GITHUB_SHA:-HEAD}}"

  case "$event_name" in
    pull_request)
      check_pull_request_range "$base_sha" "$head_sha"
      ;;
    push)
      if [[ -z "$base_sha" ]] || all_zero_sha "$base_sha"; then
        check_head_tree "$head_sha"
      else
        check_range "$base_sha" "$head_sha"
      fi
      ;;
    workflow_dispatch)
      check_head_tree "$head_sha"
      ;;
    *)
      echo "Unsupported EVENT_NAME: $event_name" >&2
      exit 2
      ;;
  esac
}

run_expect_success() {
  local label="$1"
  shift

  if ! "$@"; then
    echo "ci-text-hygiene self-test failed: expected success for $label" >&2
    exit 1
  fi
}

run_expect_failure() {
  local label="$1"
  shift

  if "$@"; then
    echo "ci-text-hygiene self-test failed: expected failure for $label" >&2
    exit 1
  fi
}

self_test() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap "rm -rf '$temp_dir'" EXIT

  git -C "$temp_dir" init -q
  git -C "$temp_dir" config user.name "CI Text Hygiene"
  git -C "$temp_dir" config user.email "ci-text-hygiene@example.invalid"
  local default_branch
  default_branch="$(git -C "$temp_dir" symbolic-ref --short HEAD)"

  printf 'clean\n' > "$temp_dir/file.txt"
  git -C "$temp_dir" add file.txt
  git -C "$temp_dir" commit -q -m "base"
  local base_sha
  base_sha="$(git -C "$temp_dir" rev-parse HEAD)"

  printf 'clean\ntrailing whitespace \n' > "$temp_dir/file.txt"
  git -C "$temp_dir" add file.txt
  git -C "$temp_dir" commit -q -m "bad whitespace"
  local whitespace_sha
  whitespace_sha="$(git -C "$temp_dir" rev-parse HEAD)"
  run_expect_failure "pull request whitespace range" \
    env EVENT_NAME=pull_request BASE_SHA="$base_sha" HEAD_SHA="$whitespace_sha" \
    bash -c "cd '$temp_dir' && '$SCRIPT_PATH' check >/dev/null 2>&1"

  git -C "$temp_dir" reset -q --hard "$base_sha"
  printf 'clean\n<<<<<<< ours\n=======\n>>>>>>> theirs\n' > "$temp_dir/conflict.txt"
  git -C "$temp_dir" add conflict.txt
  git -C "$temp_dir" commit -q -m "bad conflict marker"
  local conflict_sha
  conflict_sha="$(git -C "$temp_dir" rev-parse HEAD)"
  run_expect_failure "push conflict marker range" \
    env EVENT_NAME=push BASE_SHA="$base_sha" HEAD_SHA="$conflict_sha" \
    bash -c "cd '$temp_dir' && '$SCRIPT_PATH' check >/dev/null 2>&1"

  git -C "$temp_dir" reset -q --hard "$base_sha"
  printf 'clean\nstill clean\n' > "$temp_dir/file.txt"
  git -C "$temp_dir" add file.txt
  git -C "$temp_dir" commit -q -m "good change"
  local clean_sha
  clean_sha="$(git -C "$temp_dir" rev-parse HEAD)"
  run_expect_success "pull request clean range" \
    env EVENT_NAME=pull_request BASE_SHA="$base_sha" HEAD_SHA="$clean_sha" \
    bash -c "cd '$temp_dir' && '$SCRIPT_PATH' check >/dev/null 2>&1"

  git -C "$temp_dir" reset -q --hard "$base_sha"
  printf 'shared bad whitespace \n' > "$temp_dir/shared.txt"
  git -C "$temp_dir" add shared.txt
  git -C "$temp_dir" commit -q -m "shared bad whitespace"
  local shared_base_sha
  shared_base_sha="$(git -C "$temp_dir" rev-parse HEAD)"

  git -C "$temp_dir" checkout -q -b feature "$shared_base_sha"
  printf 'feature clean\n' > "$temp_dir/feature.txt"
  git -C "$temp_dir" add feature.txt
  git -C "$temp_dir" commit -q -m "feature clean"
  local feature_sha
  feature_sha="$(git -C "$temp_dir" rev-parse HEAD)"

  git -C "$temp_dir" checkout -q "$default_branch"
  git -C "$temp_dir" reset -q --hard "$shared_base_sha"
  printf 'shared cleaned\n' > "$temp_dir/shared.txt"
  git -C "$temp_dir" add shared.txt
  git -C "$temp_dir" commit -q -m "main cleanup"
  local advanced_base_sha
  advanced_base_sha="$(git -C "$temp_dir" rev-parse HEAD)"

  run_expect_success "pull request merge-base range ignores base-only cleanup" \
    env EVENT_NAME=pull_request BASE_SHA="$advanced_base_sha" HEAD_SHA="$feature_sha" \
    bash -c "cd '$temp_dir' && '$SCRIPT_PATH' check >/dev/null 2>&1"

  echo "ci-text-hygiene self-test: clean"
}

main() {
  local action="${1:-}"

  case "$action" in
    check)
      check
      ;;
    self-test)
      self_test
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
