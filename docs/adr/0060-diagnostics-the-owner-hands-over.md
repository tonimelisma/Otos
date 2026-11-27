# ADR 0060: Diagnostics the owner hands over

- Status: Accepted
- Date: 2026-11-26

## Context

Otos is developed from cloud sessions that never reach the owner's Mac (ADR 0061): CI's
runner builds, tests, captures and releases. What the installed app runs into on his
library — a hang, a crash, a stall the logs explain, a folder that grew — happens only on
his Mac, where no session can read it. A directly distributed app gets no crash reports
from Xcode's Organizer, which covers App Store and TestFlight apps only, and a third-party
crash reporter would send his data off the machine
(`docs/research/2026-11-26-ci-only-macos-development.md`).

## MECE Decision Scope

Owns: Help ▸ Export Diagnostics… and what it writes; keeping MetricKit's diagnostic reports.
Defers: the log facade and its lines (ADR 0015); where Otos keeps its data (ADR 0020); how
a file is published into a folder without replacing one (`ExclusivePublication`, ADR 0038).

## Decision

1. **Help ▸ Export Diagnostics…** asks for a folder (an open panel that can make one) and
   writes one new folder into it, `Otos Diagnostics <yyyy-MM-dd HH.mm.ss>` in the Mac's
   time zone (`DiagnosticsExport`):
   - `about.json`: bundle identifier, version, build, macOS, the Mac's model, when it was
     written, and the log lines' scope, start and count, or why there are none;
   - `log.ndjson`: Otos's own log lines (subsystem `net.melisma.Otos`) of the last 24 hours
     at info and above, one JSON object a line (date, category, level, message). They come
     from the system's log store, which keeps every session and which an administrator's
     account may read (`OSLogStore(scope: .system)`); where it is refused, from this
     process's own, which holds only this launch. A log that cannot be read at all is named
     in `about.json` and the rest is written;
   - `crash-reports/`: the system's crash, hang, spin and diagnostic reports whose names
     start with `Otos-` or `Otos_`, from `~/Library/Logs/DiagnosticReports`;
   - `metrickit/`: the MetricKit diagnostic reports the app kept (decision 2);
   - `storage.json`: each entry of Otos's Application Support folder, with its allocated
     bytes and file count.
2. **MetricKit's diagnostic reports are kept as they arrive.** One `MetricManager` for the
   session, and one loop over its `diagnosticReports`, detached from the main actor
   (`MetricKitRecorder`), writes each `DiagnosticReport` as JSON into
   `Application Support/<bundle id>/Diagnostics/MetricKit`, never replacing a file. They are
   Otos's own data, kept like the rest of it (no eviction). Their call stacks are binary
   images and offsets; a session symbolicates them against the release's dSYMs.
3. **The chosen folder never holds a partial export, and nothing in it is replaced.** The
   export is written in the system's scratch folder on the destination's volume and moved
   in by `ExclusivePublication`; a name already taken gets ` 2`, ` 3`…. The scratch folder
   goes however the export ends.
4. **It reports what it did.** A written export is shown in Finder, selected. One that could
   not be written shows the alert `Couldn’t Export Diagnostics` with why: the folder no
   longer exists, its disk is full, or it could not be written (DES-037). Exports run one
   at a time in the order asked, in one consumer of one ordered stream
   (`DiagnosticsExportController`, ADR 0032 rules 5 and 6).
5. **Nothing leaves the Mac by itself.** The owner hands the folder to a session (a chat's
   upload). It is never uploaded to CI, a public artifact or a third-party service: it
   holds his paths and file names.

## Rejected alternatives

- **A crash reporter (Sentry and the like).** It sends the owner's data to a third party,
  and needs a dependency ADR for a need a folder he hands over meets.
- **Uploading diagnostics to CI or to the repository.** The repository and its artifacts are
  public.
- **`OSLogStore.local()`.** It needs the `com.apple.logging.local-store` entitlement; the
  `.system` scope reads the same store for an administrator.
- **MetricKit's `MXMetricManager` subscriber.** Deprecated in the macOS 27 SDK for
  `MetricManager`'s asynchronous sequences.
- **Including debug lines.** The installed app persists them (ADR 0030), and a day of them is
  far larger than the info-and-above lines a diagnosis starts from; a session that needs
  them asks for a log taken on the Mac.

## Consequences

- A session diagnosing the installed app asks the owner for one folder, and reads its
  `log.ndjson`, reports and payloads with no access to his Mac.
- The export reads no catalog: the store is never opened twice and nothing waits on it.
- Every report and payload Otos keeps stays until the owner removes it.
