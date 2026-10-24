# ADR 0033: Time is never a stand-in for a fact that can be known

- Status: Accepted
- Last updated: 2026-10-23

## Context

Fixed time limits kept standing in for facts something could have reported. Test waits
with wall-clock deadlines failed tests whose state was still arriving and hid tests that
asserted nothing: `settlementConversionAfterPublishBStillSuffixDueToRealFile` passed on
`nil` after its 5 s loop in all 88 logged runs. In the app, a removable source resumed 2 s
after an unmount announced itself, a debounce waited for a quiet second before
reconciling filesystem events, enrichment claims expired after 300 s and were renewed
every 120 s, and a File Provider download was polled every 250 ms. Each was a guess at a
fact: that an unmount had failed, that a burst had ended, that a claimant was alive,
that bytes had arrived.

The research behind the replacements:

- `docs/research/2026-10-23-removable-and-camera-state-reports.md` — a refused unmount
  is reported to its caller only; ImageCaptureCore reports no fact that a catalog is
  whole.
- `docs/research/2026-10-23-cadence-audit.md` — which rate limits a measurement
  supports.
- `docs/research/2026-10-23-materialization-arrival.md` — the kernel clearing
  `SF_DATALESS` arrives as a vnode attribute change on an event-only descriptor.

## Decision

Never use time to stand in for a fact that can be known. If something can report that
work finished, state changed, or an item is ready, wait on that report. Time appears only
where nothing can report the fact, and the code says which case it is:

| Tag | Meaning |
| --- | --- |
| `deadline` | An external system that may never answer — a File Provider, a camera's PTP link, a process outside Otos. The limit is a product decision about when the user is told, or when work resumes. |
| `backoff` | The pause after an external failure before trying again. |
| `schedule` | A schedule the product defines: a 24 h integrity scan, a check's heartbeat. |
| `measurement` | Code whose job is to measure time: a stall monitor, a sampler, a benchmark's pacing. |
| `poll` | Re-checking a fact that nothing reports; time decides only how often to look, never the outcome. Test waits on in-process state use it, with no deadline. |
| `cadence <path>` | A rate limit — a cadence or a debounce — standing on the recorded measurement at `<path>`. Without one, the work is coalesced through its owner instead (ADR 0032). |

Every wait on time in `Otos/`, `OtosTests/` and `script/` carries a `time:` tag with one
of these on its line or in the comment directly above it. `script/time-guard.sh` checks
that, and that a cadence's measurement exists, in `script/check.sh`'s fast gates and in
CI. There is no allowlist: a wait without a tag fails, and a tag is a claim a reviewer
checks against the code beside it.

### Which clock

Every interval and deadline inside one process is taken on `ContinuousClock` and held as
an `Instant` or a `Duration`: it is monotonic, so a wall-clock change, an NTP step or a
manual date change never shortens, lengthens or reverses it, and it keeps counting
across system sleep. `DiagnosticsTiming` accepts only instants and durations. `Date` is
for facts that outlive the process or are shown to a person — a persisted timestamp, a
capture time, a "Yesterday" label — and is never used to measure an interval. The
SwiftLint rule `wall_clock_interval` rejects wall-clock interval arithmetic
(`Date()` with `timeIntervalSince(`/`addingTimeInterval`, `timeIntervalSinceNow`,
`Date.distantPast`/`distantFuture`).

## Alternatives considered

- **An allowlist of permitted call sites.** Rejected: it records that a site was
  excused, not why, and it grows by exception.
- **A typed wrapper that every wait goes through.** Rejected for now: it moves the same
  claim into a type without checking it any better, and shell scripts cannot use it.
- **Banning time outright.** Impossible: some facts are never reported — a provider
  that silently drops a request, an unmount another process asked for that the system
  refused, a legacy mouse that never says scrolling stopped.

## Consequences

- A guard failure names the file and line; the fix is to wait on a report, or to tag
  the wait with the case it is and why.
- Test waits keep `waitUntil` / `waitForValue`: they poll owned predicates with no
  deadline, so a condition that never holds is a hang that `check.sh` reports.
- The ADR owns the rule and its categories. ADR 0032 owns how owners coalesce requests;
  the research documents above own the measurements.
