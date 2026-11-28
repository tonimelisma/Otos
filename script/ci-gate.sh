#!/usr/bin/env bash
# Waits for a commit's `CI gate` and says how it ended (ADR 0062): script/release.sh publishes
# only after it passed.
#
#   script/ci-gate.sh <sha>     exit 0: the gate succeeded; 3: it was cancelled (a newer push
#                               superseded the run); 1: it failed, or never finished in time
#
# It reads the newest `CI gate` check run of GitHub Actions on the commit (gh, with
# GITHUB_REPOSITORY and a token that reads checks). A check that has not started yet is waited
# for: the release starts on the push, beside CI.
set -euo pipefail

sha="${1:?usage: script/ci-gate.sh <sha>}"
: "${GITHUB_REPOSITORY:?the repository is needed}"
# time: deadline — CI's own jobs are bounded (120 minutes); past that the release gives up.
deadline=$(( $(date +%s) + ${OTOS_CI_GATE_DEADLINE_SECONDS:-7800} ))
started="$(date +%s)"
while :; do
  state="$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha/check-runs?check_name=CI%20gate&per_page=100" \
    --jq '[.check_runs[] | select(.app.slug == "github-actions")]
      | if length == 0 then "absent" else (max_by(.started_at) | if .status == "completed" then .conclusion else .status end) end')" \
    || state="unreadable"
  case "$state" in
    success)
      echo "op=ci.gate commit=$sha outcome=success waitedSeconds=$(( $(date +%s) - started ))"
      exit 0 ;;
    cancelled)
      echo "op=ci.gate commit=$sha outcome=cancelled"
      exit 3 ;;
    absent | queued | in_progress | pending | waiting | requested | unreadable) ;;
    *)
      echo "op=ci.gate commit=$sha outcome=$state" >&2
      exit 1 ;;
  esac
  if (( $(date +%s) >= deadline )); then
    echo "op=ci.gate commit=$sha outcome=timedOut last=$state" >&2
    exit 1
  fi
  # time: poll — GitHub reports a check's completion only to webhooks; this job re-reads it.
  sleep 10
done
