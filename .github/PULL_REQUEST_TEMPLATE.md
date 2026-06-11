## Summary

- <item>

## Spec, Requirements, And ADRs

- Spec:
- Requirement IDs:
- ADRs:
- Definition of Ready complete:

## Architecture

- Alternatives considered:
- Selected approach:
- Why this is correct:
- Retirement proof, if applicable:

## Verification

- Local `script/verify.sh`:
- Xcode version:
- Focused tests:
- Additional tests:

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

- Docs updated:
- Logs avoid raw paths, filenames, thumbnails, EXIF payloads, and user content:
- Fixture or media impact:
- Persistence/schema impact:

## Risks And Follow-Up

- Unresolved risks:
- Follow-up work:

## Foundation Checklist

- [ ] No compatibility shims.
- [ ] No patch-only workaround.
- [ ] No legacy architecture or stale naming.
- [ ] No effort-based compromise.
- [ ] No fabricated user-visible or domain facts.
- [ ] One user action has one implementation path.
- [ ] Meaningful paths are instrumented with OSLog/signposts.
- [ ] Main-actor work stays under the 100 ms hang threshold, with stricter review for continuous interactions.
