## Summary

- 

## Spec And ADRs

- Spec:
- ADRs:

## Architecture

- Alternatives considered:
- Selected approach:
- Why this is correct:

## Verification

- Local `script/verify.sh`:
- UI smoke `script/test-ui.sh` when applicable:
- Additional tests:
- Instrumentation or profiling evidence:

## CI

- GitHub Actions:
- If CI did not run, paste the GitHub exhausted Actions quota evidence here. CI may only be waived for confirmed quota depletion.

## Privacy And Media

- Logs avoid raw paths, filenames, thumbnails, EXIF payloads, and user content:
- Fixture or media impact:

## Foundation Checklist

- [ ] No compatibility shims.
- [ ] No patch-only workaround.
- [ ] No legacy architecture or stale naming.
- [ ] No effort-based compromise.
- [ ] Meaningful paths are instrumented with OSLog/signposts.
- [ ] Main-actor work stays under the 100 ms hang threshold.
