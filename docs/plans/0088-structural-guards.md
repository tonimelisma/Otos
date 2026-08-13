# Plan 0088 — Structural Guards For Absence Invariants

## Goal

Give the 36 requirement rows that assert an **absence** a proof class that can
actually fail. A unit test cannot prove "shall never" — it can only sample. A
structural guard over the whole tree can.

Scope is **new `script/guard-*.sh` checks, their self-tests, wiring into
`verify.sh`, and the requirement rows they close**. One small production move
(Stage 4). Depends on plan 0087 (the rows must be reset to honest debt before a
guard can close them).

## Why now

`docs/requirements.md` has 36 rows whose requirement text contains "shall not",
"shall never", "never", "out of product scope", or "zero":

```
ARC-002 ARC-002A ARC-009 ARC-011 ARC-014 ARC-015 ARC-020 ARC-023 ARC-028
ARC-031 ARC-033 ARC-034 ARC-038 ARC-041 ARC-042 ARC-045 ARC-046 ARC-049
ARC-053 MED-002 MED-004 APP-006 APP-008 APP-010 APP-011 APP-012 APP-015
APP-020 APP-021 ENR-003 ENR-004 ENR-005 ENR-007 ENR-008 ENR-009 ENR-013
```

Exactly one of them — ARC-042 — is proven by a guard. It is also the only one
that has ever caught a real drift: `script/check-no-unchecked-sendable.sh:2-4`
records that the requirement "drifted from 0 to 14 without one failing gate"
while it was verified by the string `manual:`.

Not all 36 need a guard: many contain an absence clause inside an otherwise
behavioral requirement (ENR-008's breaker, APP-015's monotonic paint), and those
are better served by the behavioral tests in plan 0089. This plan takes the rows
where absence **is** the requirement.

## Root cause

An absence invariant is a property of the whole codebase, not of one execution.
Sampling it with a unit test is a category error: `catalogMediaExcludesAudio`
proves one function rejects one input, while MED-004 claims 32,340 lines contain
no audio workflow anywhere. When the only accepted proof class is a unit test,
the honest options are a tautology or permanent `unverified:` — which is exactly
the fork plan 0082 hit, and it chose tautology.

Guards are cheap, they run in `verify.sh` in under a second, and they fail loudly
on the drift they exist to prevent.

## Inventory

Six guards. Each is one file under `script/`, follows the shape of
`check-no-unchecked-sendable.sh` (a `check_root` function, an explicit
`ALLOWLIST` with a justification comment per entry, and a `self-test` mode with
positive and negative fixtures), and is cited as
`` `script/guard-x.sh#self-test` ``.

| Guard | Closes | Asserts | Measured today |
| --- | --- | --- | --- |
| G1 `guard-unsandboxed.sh` | ARC-002 | `Otos.xcodeproj/project.pbxproj` contains no `com.apple.security.app-sandbox` and no `CODE_SIGN_ENTITLEMENTS`; no source references `startAccessingSecurityScopedResource`, `bookmarkData(options:`, or `.withSecurityScope` | 0 hits — guard passes on arrival |
| G2 `guard-single-main-window.sh` | ARC-014, ARC-001 | `Otos/OtosApp.swift` declares exactly one `Window(` scene and zero `WindowGroup(` | 1 `Window("Otos", id: "main")` at `:39`, 0 `WindowGroup` |
| G3 `guard-view-passivity.sh` | ARC-011, ARC-015 | No file under `Otos/Views/` references `CatalogStore`, `CatalogProjection`, or `GRDB` outside the allowlist | 1 real hit — see Stage 4 |
| G4 `guard-no-audio.sh` | MED-004 | No source references `AVAudio`, `UTType.audio`, `kUTTypeAudio`, `AVAudioSession`, or `audioPlayer` | 0 hits — guard passes on arrival |
| G5 `guard-no-writes-into-media.sh` | ARC-018 (and supports MED-001) | Only the import/reorganization executors may reference filesystem-write APIs (`FileManager.createFile`, `.copyItem`, `.moveItem`, `.removeItem`, `write(to:`) — allowlist is `MediaImportExecutor`, `ReorganizationExecutor`, `ThumbnailStore`, `DeviceStagingRegistry`, and Application Support paths | needs measuring in Stage 1 |
| G6 `guard-smoke-run-busy.sh` | ARC-002A | Drives `script/smoke-run.sh`'s real busy predicate against sqlite fixtures | no coverage today |

G6 is not a grep. It is a behavioral test of a shell function, and it is the most
valuable guard in the set because ARC-002A protects the user's in-flight import
from being killed.

## Research grounding

- `script/check-no-unchecked-sendable.sh` — the established pattern, including
  the `ALLOWLIST` + `is_allowlisted` + `self-test` shape and the ARC-042 citation
  form `` `script/check-no-unchecked-sendable.sh#self-test` ``.
- `script/requirements-authority-check.sh:172-176` — script citations are already
  a valid proof class; the gate greps the script for the named symbol.
- `script/smoke-run.sh:104-133` — `has_active_operational_work()` reads
  `active_file_operation` and `active_reorganization_component` via
  `sqlite3 -readonly`, treats any sqlite error as busy, and
  `is_import_active()` (`:131-133`) aliases it. `:142`, `:265`, `:289` are the
  three call sites that gate `kill`.
- `Otos/OtosApp.swift:39` — `Window("Otos", id: "main")`, the single-window scene.
- `Otos.xcodeproj/project.pbxproj` — `grep -c 'com.apple.security.app-sandbox\|CODE_SIGN_ENTITLEMENTS'` returns 0.

## Stages

### Stage 1 — G1, G2, G4 (the three that pass on arrival)

Write all three plus self-tests. Each passes against the current tree, so the
whole value is in the negative fixture: the self-test must build a temp root that
**violates** the rule and assert the guard fails on it. A guard without a failing
fixture is a guard nobody has proven works.

For G2, the negative fixture is a temp `OtosApp.swift` containing `WindowGroup(`;
the guard must fail. That single fixture is the proof ARC-014 has never had.

Cite each guard in its rows, replacing the `unverified:` debt plan 0087 left.

Also measure G5's real hit list in this stage and record it in the PR — the
allowlist above is a hypothesis until then. If the hit list shows writes from
files not in the proposed allowlist, that is a finding to report, not an
allowlist entry to add silently.

Verification: `bash script/verify.sh` green; each guard's `self-test` passes;
each guard fails on its negative fixture.

### Stage 2 — G6, the smoke-run busy predicate

The highest-value guard. `script/smoke-run.sh` will `kill` the app, and nothing
proves it refuses to when work is in flight.

Make the predicate testable without running the app: `source` the script with a
guard so its main body does not execute (or extract
`has_active_operational_work` into `script/lib/` and have both `smoke-run.sh` and
the guard source it — prefer this, it is the smaller correct structure). Then, in
`self-test`:

1. Build a temp sqlite DB with the real schema for `active_file_operation` and
   `active_reorganization_component`.
2. No rows → predicate reports idle, exit non-zero from the busy check.
3. Insert an `active_file_operation` row for root A → busy, **including when the
   queried root is B** (ARC-002A: "even for a different root").
4. Insert an `active_reorganization_component` row → busy.
5. Point `CATALOG_DB` at a corrupt/unreadable file → busy (any sqlite error
   counts as busy).
6. `sqlite3` absent from `PATH` → busy (`:113-115`).
7. Assert `is_import_active` and `has_active_operational_work` return identically
   for all six fixtures.

Cases 3, 5, and 6 are the ones that protect the user's data; case 5 in particular
is the one a naive implementation gets backwards by treating an error as idle.

Cite as `` `script/guard-smoke-run-busy.sh#self-test` `` on ARC-002A, replacing
the three false journal citations plan 0087 reset.

Verification: temporarily invert the error branch in the predicate
(`sqlite3` error → idle) and confirm the guard fails. Revert.

### Stage 3 — G5, no writes into user media folders

Write the guard against the hit list measured in Stage 1. Every allowlist entry
carries a one-line justification naming *why* that file legitimately writes and
*where* it writes (Application Support, staging, or an explicit user-initiated
transfer).

This guard supports but does not close MED-001 — a static check proves no
unexpected file *calls* a write API; it cannot prove the writes that do happen
stay outside library roots. That is the runtime harness in plan 0089. Keep
MED-001's `unverified:` debt until then, and say so in the row.

### Stage 4 — Move `MediaTileDetailReader` out of the view layer

G3 has one real hit, and it is a genuine boundary problem rather than an
allowlist candidate.

`Otos/Views/MediaGridSupport.swift:12-30` defines `MediaTileDetailReader`, which
holds `private let store: CatalogStore` and calls
`store.mediaTileDetails(for:)`. It is not a SwiftUI view — it is a reader backing
the AppKit bridge, and the pull-based detail query is a deliberate part of the
grid design (`docs/architecture.md:76-84`). The behavior is right; the **location**
contradicts the boundary that ARC-011/ARC-015 assert and that G3 must enforce.

Move the type to `Otos/Services/MediaTileDetailReader.swift`, unchanged. Update
the file guide in `MediaGridSupport.swift` (which currently says "this file keeps
the detail reader") and `docs/architecture.md` if it names the location. Then G3's
allowlist contains exactly one entry:

```bash
ALLOWLIST=(
  # SwiftUI #Preview constructs a real in-memory store; preview-only, not a
  # runtime view→store path. ContentView.swift:275-280.
  "Otos/ContentView.swift"
)
```

A `#Preview`-only exception is narrow enough to be honest. If a future hit
appears in `ContentView.swift` outside `#Preview`, tighten G3 to check the
enclosing declaration rather than widening the allowlist.

Verification: `bash script/verify.sh` green; G3 self-test fails on a fixture
where a `Otos/Views/` file references `CatalogStore`.

## Verification

- `bash script/verify.sh` green with all six guards wired in after
  `check-no-unchecked-sendable.sh`.
- Each guard: `self-test` passes, negative fixture fails, runtime under 1 s.
- Rows ARC-001, ARC-002, ARC-002A, ARC-011, ARC-014, ARC-015, MED-004 cite a
  guard and carry no `unverified:` entry.
- MED-001 and ARC-018 still carry bounded debt pointing at plan 0089.

## Non-goals and guards

- Guards are **scripts**, never Swift tests that read source as text — AGENTS.md
  forbids the latter and CI enforces it. The distinction is not cosmetic: a
  script is a tree-wide structural check, a test is a behavioral sample.
- Do not write a guard that greps for the *presence* of good code. Guards assert
  absence of forbidden constructs; presence is what behavioral tests are for.
- Do not add an allowlist entry to make a guard pass without a one-line
  justification naming the file and why. An unjustified allowlist is how ARC-042
  drifted 0 → 14.
- Do not extend G5 into a general "no filesystem writes" rule. Otos writes
  constantly — to Application Support. The invariant is about *user media
  folders*, and the guard must say so in its failure message.
