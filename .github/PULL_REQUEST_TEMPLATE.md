## Summary

- <item>

## Requirements And ADRs

- Current requirement IDs:
- ADRs added/updated:
- Plan (if any; delete when done):

## Architecture

- Alternatives considered (when a real decision was made):
- Selected approach:
- Why this is correct / simplest:

## Verification

- Local `script/verify.sh`:
- Xcode version:
- Focused tests:

## Performance And Instrumentation

- Instrumentation/log categories changed:
- `script/logs.sh` evidence:
- `script/profile.sh` trace paths for performance-sensitive changes:
- Worst span/stall summary or blocker:

## Code Smells Observed

- Smells found:
- Addressed:
- Accepted or out of scope:

## CI

- GitHub Actions:
- If CI did not run, paste the GitHub exhausted Actions quota evidence here. CI may only be waived for confirmed quota depletion.
- Note: remote CI does not run Xcode 27 build/test until a real Xcode 27 runner exists; local `script/verify.sh` evidence is required.

## Docs And Privacy

- Docs updated (`requirements.md` / ADRs / `architecture.md` / research / plans):
- Obsolete docs/comments deleted:
- Logs contain only bounded diagnostic payloads; secrets, credentials,
  thumbnails, binary media, and unbounded metadata are absent:
- Fixture or media impact:
- Persistence/schema impact:

## Risks And Follow-Up

- Unresolved risks:
- Follow-up work:
- Non-blocking after-DoD user-operated verification, if any:

## Final DoD Report

Do not fill this section before merge. Do not post a review handoff, partial,
pre-merge, or ready-for-review DoD report.

After the PR is merged, local `main` is updated, required post-merge verification
is complete, branch/worktree cleanup is complete, increment stashes are cleared,
stale branches/worktrees are reviewed, and the final working tree is clean, post
the single final green/red DoD report as a PR comment **and send the same full
report to the user** (never a summary with a link).

## Foundation Checklist

- [ ] No compatibility shims.
- [ ] No patch-only workaround.
- [ ] No legacy architecture or stale naming.
- [ ] No effort-based compromise.
- [ ] No fabricated user-visible or domain facts.
- [ ] One user action has one implementation path.
- [ ] Self-reviewed against the AGENTS.md review bar; blockers and majors resolved.
- [ ] Affected requirements, ADRs, and `docs/architecture.md` describe the landed
      design; obsolete documents were deleted.
- [ ] Affected file guides and comments explain current mechanics and rationale,
      with no stale increment history.
- [ ] No new `docs/specs/` files; no process rows added to `requirements.md`;
      no source-text tests.
- [ ] Meaningful paths are instrumented with OSLog/signposts.
- [ ] Main-actor work stays under the 100 ms hang threshold, with stricter review for continuous interactions.
