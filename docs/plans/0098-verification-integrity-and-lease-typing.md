# 0098 — Verification Integrity, And Typing The Lease

## Read first

- `docs/adr/0015-observability.md` — the logging facade and the agent's windows.
  Increment 1 fixes a defect that has made **every test-process log line
  unreadable** by `script/logs.sh` since the facade was written; plan 0097's
  `--process xctest` flag was added to read logs that the subsystem filter could
  never match.
- `docs/adr/0023-test-architecture.md` — the unhosted test bundle. That is *why*
  `Bundle.main` is `xctest` under test, which is the mechanism of the defect above.
- `docs/adr/0026-settled-naming-and-card-erase.md` — the settled-naming gate and
  the permanent-deletion boundary. Increments 2 and 3 correct both.
- `docs/adr/0024-import-source-readiness-gate.md` — the readiness gate. Increment 4
  retires a test that asserts a phase the gate replaced.
- `docs/adr/0025-volume-aware-path-equality.md` — volume capabilities. Increment 5
  makes the `isKnown` fact it introduced actually reachable.

This plan assumes no prior context. Every increment states its goal, the exact
steps with file and line references, how to verify, and how to roll back.

---

## What is wrong today

`main` is red at `e53078c`, and has been red since at least `40261bf`. Measured
on 2026-08-20 against `e53078c`:

```
script/verify.sh  → exit 1   (SwiftFormat lint fails; test.sh never runs)
script/test.sh    → exit 65  (5 failing tests)
```

```
MediaOperationCoordinatorTests.catalogChangeWakesWaitingForMetadataSource()
MediaOperationCoordinatorAdversarialTests.catalogChangeWakesWaitingForMetadataSourceDeterministic()
MediaOperationCoordinatorAdversarialTests.importIsRefusedWhileDeviceIsStillEnumerating()
ImportExecutionProgressTests.failedCopySourceSurvivesEraseSweep()
ImportExecutionProgressTests.zeroCopyPlanWithDeleteRequestedExecutesDeletion()
```

The parent commit `40261bf` was built in a throwaway worktree and the same tests
run against it: 4 of the 5 fail there too (`failedCopySourceSurvivesEraseSweep`
did not exist yet). So plan 0097 did not introduce the red; it landed on top of
it, and changed one failure into a worse one.

PR 291's Verification section claimed `bash script/test.sh ✅`. PR 292's closure
comment claimed "local `script/verify.sh` was green". Neither is true on this
tree. Two structural gaps allowed both claims to be made in good faith, and
increment 1 closes both.

### D1 · `verify.sh` lets a formatting nit hide the whole test suite

`script/verify.sh` runs the static gates as a backgrounded shell function and
then `wait`s on them under `set -e`:

```bash
run_static_gates &            # guards + check-doc-citations + lint.sh
static_gates_pid=$!
"$ROOT_DIR/script/build.sh"
wait "$static_gates_pid"      # ← set -e aborts here when lint fails
"$ROOT_DIR/script/test.sh"    # ← never reached
```

`script/lint.sh` currently exits 1 on five files, all touched by plan 0097
(`MediaOperationGateway.swift`, `FilesystemNamespaceSemantics+NameKey.swift`,
`MediaOperationModels.swift`, `CatalogStorePersistence.swift`,
`MediaImportExecutor.swift`). The cheapest gate in the script masks the most
expensive one, and the exit code cannot distinguish "badly wrapped `if`" from
"five failing tests".

The output is also unreadable: each guard runs `check` then `self-test`, and every
self-test deliberately prints `FAIL:` while proving it can detect a bad oracle.
A real failure is one `FAIL:` line among eight expected ones, in a 1,599-line log.

### D2 · No test-process log line has ever been readable

`OtosLog.subsystem` (`Otos/Support/Instrumentation.swift:5`) is:

```swift
static let subsystem = Bundle.main.bundleIdentifier ?? "net.melisma.Otos"
```

Under the unhosted test bundle (ADR 0023) `Bundle.main` is the `xctest` tool, so
the subsystem resolves to `com.apple.dt.xctest.tool` and the `??` fallback never
fires. Measured during a failing-test run on 2026-08-20:

```
$ log show --predicate 'process == "xctest"' --info --debug | grep 'op=' | head -1
xctest: (OtosKit) [com.apple.dt.xctest.tool:Catalog] op=catalog.start phase=start
                                ^^^^^^^^^^^^^^^^^^^^^ not net.melisma.Otos
```

`script/logs.sh` hardcodes `SUBSYSTEM="net.melisma.Otos"` in its predicate, so
`script/logs.sh show --process xctest` returns `{"count":0,"finished":1}` for a
run that emitted 176 `op=` lines. The subsystem is an identity of *this code*,
not of whichever host process loaded it, and deriving it from `Bundle.main` was
always wrong — it merely became invisible when the bundle went unhosted.

This is the first increment because ADR 0015 says "No human reads logs — the
agent does", and D3 and D5 below were both diagnosed only after fixing it.

### D3 · A file with a known capture date waits for metadata forever

`MediaOperationGateway.fetchPlanningSourceMedia`
(`Otos/Stores/MediaOperationGateway.swift:34-45`) derives `namingFactState` from
one input — `EnrichmentLeaseGateway.metadataStalenessSQLPredicate()`:

```sql
enriched_source_size IS NULL
   OR enriched_source_mtime IS NULL
   OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
   OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
      <> COALESCE(enriched_source_mtime, -1)
```

That predicate answers **"should enrichment run again?"**. `namingFactState`
asks a different question: **"do we know enough to name this file?"**. Using one
answer for both questions is the state-duplication smell, and the two questions
diverge on a representable state:

| fact | value |
|---|---|
| `content_modified_at_unix` | `NULL` (scanner reported no mtime) |
| `enriched_source_mtime` | `NULL` (enrichment reported no mtime) |
| `capture_wall_compact` | **set** (enrichment found an embedded capture date) |

`enriched_source_mtime IS NULL` makes the staleness predicate permanently true,
so `naming_settled` is `0` forever. The gateway's second branch requires
`modified != nil`, which is false. The state falls through to `.pending`, and
`MediaOperationCoordinator.shouldWaitForMetadata` holds the source in
`.waitingForMetadata` — **for a file whose capture date is already known and
which nothing further can improve**. The bar sits on "Checking the card…"
permanently.

`PlanningFileFacts.hasAnyDate` expressly models `captureWallCompact != nil ||
contentModifiedAt != nil`, so a nil-mtime-with-capture-wall asset is a state the
domain admits. Two tests construct exactly it, and both fail.

### D4 · Lease acquisition failure is reported to the user as "The card was removed"

`MediaImportExecutor.execute` (`Otos/Services/MediaImportExecutor.swift:250-262`)
acquires a source namespace lease before the first byte is copied:

```swift
guard let lease = await store.acquireNamespaceMutationLease(for: sourceRoot, owner: .sourceErase)
else {
    if let namespaceLease { _ = await store.releaseNamespaceMutationLease(namespaceLease) }
    return .failed(reason: .sourceRemoved)
}
```

`CatalogStore.acquireNamespaceMutationLease` (`Otos/Stores/CatalogStore.swift:4098`)
returns `nil` for two different facts:

```swift
guard roots[rootPath] != nil, namespaceMutationLeases[rootPath] == nil else { return nil }
//    ^ root not registered   ^ someone else holds it
```

`.sourceRemoved` renders as **"The card was removed"**
(`Otos/Views/ImportBarPresentation.swift:596`). So a card that is physically
present, but whose namespace lease is briefly held by `MediaTrashCoordinator`, by
`LibraryReorganizationRunner`, or by this executor's own unreleased recovery
lease (D6), aborts the entire import before copying anything and tells the user
something false. `Otos` does not fabricate user-visible facts.

The scope is also wrong. The erase lease is needed only by `eraseSourceFiles`,
which runs *after* every copy completes, yet it is held for the whole batch —
hours for a full card. While held it suppresses filesystem reconcile
(`CatalogStore.swift:3149`), defers scan scheduling (`:2589`), and makes
`removeLibrary` on the source throw (`:1503`).

Both `ImportExecutionProgressTests` failures land on this guard. Their fixture
registers only the destination root, so the source lease can never be acquired.

### D5 · A stale test asserts a phase the readiness gate replaced

`importIsRefusedWhileDeviceIsStillEnumerating` waits for
`.failed(reason: .unexpected(detail: "executionUnavailable"))`, and its comment
asserts that `markExecutionUnavailable` "sets `session.phase` to
`.failed(.unexpected("executionUnavailable"))`".

It does not. `MediaOperationCoordinator.markExecutionUnavailable`
(`:449-463`) sets the dedicated phase `.executionUnavailable`, which
`presentation(for:)` (`:1314`) maps to the dedicated state
`.executionUnavailable`, which the bar renders at
`Otos/Views/ImportBarPresentation.swift:145`.

The product is right and the test is stale. `.unexpected(detail:)` is documented
as "the one case whose detail is for the log, never the bar"
(`MediaOperationModels.swift:167`); routing a known, named condition through it
would be exactly the stringly-typed-domain-fact smell. The typed state is the
correct design, so the test moves to it.

### D6 · Erase recovery releases its lease into a detached task

`MediaImportExecutor.recoverSourceErase` (`:580-585`):

```swift
guard let lease = await store.acquireNamespaceMutationLease(for: operation.sourceRootPath, owner: .sourceErase)
else { return }
defer { Task { _ = await store.releaseNamespaceMutationLease(lease) } }
```

The caller loops over every journaled erase (`:157-160`), and every entry from one
card shares a `sourceRootPath`. `defer` only *enqueues* the release; the next
iteration's acquire races it. On loss the `guard … else { return }` bails with no
log at all, leaving rows in `active_source_erase` and files on the card the user
asked to reclaim. A lease left held by a still-pending release task then surfaces
through D4 as "The card was removed" on the next import.

Two rules broken: unstructured `Task` with no owner or cancellation path, and a
destructive path whose failure branch is unobservable.

### D7 · The `isKnown` capability fact can never be true-negative

`FilesystemNamespaceSemantics.probeVolumeCapabilities`
(`Otos/Services/FilesystemNamespaceSemantics+NameKey.swift:99`) is the sole
production producer of `VolumeNamespaceCapabilities`
(`RemovableVolumeMonitor.swift:274`):

```swift
let values = try? rootURL.resourceValues(forKeys: [...])
let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false
return VolumeNamespaceCapabilities(isCaseSensitive: caseSensitive, prefersDecomposedUnicode: true)
```

`isKnown` defaults to `true`, so a **failed probe** is recorded as a known fact.
The `isKnown` flag plan 0097 introduced, the `permitsDestructiveReconciliation`
query built on it, and the `RootNamespace` type that owns it are therefore all
inert: nothing in `Otos/` can ever observe `isKnown == false` from a live volume.

The two "unknown" values also disagree. `VolumeNamespaceCapabilities.unknown` is
`(caseSensitive: false, decomposed: true, isKnown: false)`, but the database
loader (`CatalogStorePersistence.swift:647-649`) builds NULL rows as
`(false, false, isKnown: false)` because `prefersDecomposedUnicode` reads
`== 1`. `nameKey` branches on `prefersDecomposedUnicode`, so the same relative
path produces different keys depending on which "unknown" a caller holds — a
divergence invisible on ASCII paths and live on every accented filename.

`prefersDecomposedUnicode` is additionally hardcoded `true` and probed nowhere,
despite being named as a per-volume fact.

### D8 · Dead abstractions, and a shim the rules forbid

- `RootNamespace` (`FilesystemNamespaceSemantics+NameKey.swift:57`) declares
  itself "The one owner of a root's filesystem namespace rules. Callers must
  carry this value". No caller does; its only references are in
  `OtosTests/RootNamespaceTests.swift`. `permitsDestructiveReconciliation` is
  referenced nowhere at all.
- `CatalogPath.relativePathIfContained` (`CatalogPath.swift:61`) is a body-for-body
  alias of `relativePath` with a doc comment describing semantics the original
  already had.
- `PlanningFileFacts.isNamingFactSettled` (`MediaOperationModels.swift:100`)
  documents itself as a "Compatibility-shaped query". `AGENTS.md`'s first
  non-negotiable is "Do not add compatibility shims".
- `MediaOperationPlanTotals.eraseCount` has no reader at `40261bf` or `e53078c`.
  Plan 0097 changed its meaning and plumbed it through `MediaTransferPlanner`
  anyway.
- `SourceEraser` (`MediaImportExecutor.swift:9`) documents itself as the sole
  owner of destructive source deletion and blocks `.library` as read-only, while
  `eraseSourceFile` (`:634`) still deletes `.library` paths through its own
  `FileManager.removeItem`. Both `.library` branches are unreachable
  (`MediaOperationCoordinator.isExecutableSource` returns `false` for `.library`),
  so this is a false invariant guarding dead code.
- `FilesystemNameKey`'s custom `==`/`hash` iterate `rawValue.utf8` to make
  comparison byte-exact rather than Unicode-canonical. That is correct and is the
  most important property in the file, and nothing says so.

---

## Increments

Each increment is one PR, in its own worktree, verified with `script/verify.sh`
before it is opened. Increments 1–4 are the fix that greens `main` and land in
order; 5–7 follow once the baseline is trustworthy.

### Increment 1 · Verification and observability integrity

**Goal.** A failing gate can never again hide the test suite, and the agent can
read a test run's logs.

**Steps.**
1. `Otos/Support/Instrumentation.swift:5` — replace
   `Bundle.main.bundleIdentifier ?? "net.melisma.Otos"` with the constant
   `"net.melisma.Otos"`, with a comment naming the unhosted-bundle reason.
2. `script/verify.sh` — collect the static-gate status instead of letting `wait`
   abort the script; always run `script/test.sh`; exit non-zero if either failed,
   and print a final summary naming which stage failed.
3. `script/verify.sh` — run each guard's `self-test` with its expected `FAIL:`
   oracle output suppressed, so the only `FAIL:` lines in the log are real.
4. `swiftformat` the five files `script/lint.sh` rejects.

**Verify.** `script/verify.sh` reaches `script/test.sh` and reports the 5 test
failures with a non-zero exit; `script/logs.sh show --last 5m --process xctest`
returns a non-zero `count` after a test run.

**Rollback.** Revert the commit; no schema, no behavior.

### Increment 2 · Naming facts answer the naming question

**Goal.** A file whose capture date is known is never held in
`.waitingForMetadata`.

**Steps.**
1. `Otos/Stores/MediaOperationGateway.swift` — derive `namingFactState` as:
   `.settled` when enrichment is current for these file facts; else `.terminal`
   when `capture_wall_compact` is present **or** `content_modified_at_unix` is
   present; else `.pending`. Both non-pending cases keep
   `isNamingFactSettled == true`.
2. Update the branch comment to state both terminal fallbacks and why a present
   capture wall is terminal (nothing enrichment can add improves the *name*).

**Verify.** `catalogChangeWakesWaitingForMetadataSource` and
`catalogChangeWakesWaitingForMetadataSourceDeterministic` pass;
`import.readiness phase=waitingForMetadata` appears before the enrichment batch
and not after it, read via `script/logs.sh --process xctest`.

**Rollback.** Revert; the derivation is a pure read-side mapping.

### Increment 3 · The lease says which fact it means

**Goal.** No caller can confuse "another owner holds this root" with "this root
is gone", and a busy source namespace never aborts a copy.

**Steps.**
1. `Otos/Models/ActiveReorganizationModels.swift` — add
   `RootNamespaceLeaseAcquisition { case acquired(RootNamespaceMutationLease);
   case busy(owner: RootNamespaceMutationOwner); case rootNotRegistered }`.
2. `Otos/Stores/CatalogStore.swift:4094` — return the typed result. Update
   `MediaTrashCoordinator`, `LibraryReorganizationRunner`, and
   `MediaImportExecutor` call sites to switch on it.
3. `MediaImportExecutor.execute` — delete the source-lease acquisition and the
   `.sourceRemoved` return at `:250-262`. Move acquisition into
   `eraseSourceFiles`, after the copy phase.
4. `MediaImportExecutor.eraseSourceFiles` — on `.busy` or `.rootNotRegistered`,
   return an `EraseOutcome` whose `failedCount` reflects the un-erased candidates
   and log `op=import.erase phase=blocked reason=…`, so the bar reports an
   incomplete erase (which `import-bar.md` already specifies) rather than a
   failed import.
5. `MediaImportExecutor.recoverSourceErase` — acquire once for the whole recovery
   loop, `await` the release, and log the acquisition-failure branch.

**Verify.** `zeroCopyPlanWithDeleteRequestedExecutesDeletion` and
`failedCopySourceSurvivesEraseSweep` pass. A new test proves that a source root
held by another owner completes the copy and reports an incomplete erase, and
that a multi-entry erase journal fully recovers.

**Rollback.** Revert; no schema change.

### Increment 4 · The device test asserts the state the product has

**Goal.** `main` is green.

**Steps.**
1. `OtosTests/MediaOperationCoordinatorAdversarialTests.swift:1628-1640` — wait
   for `.executionUnavailable` and assert its summary, replacing the
   `.failed(.unexpected("executionUnavailable"))` expectation and the stale
   comment that describes it.

**Verify.** `script/verify.sh` green end to end.

**Rollback.** Revert; test-only.

### Increment 5 · Volume capabilities are known, or they are not

**Goal.** `isKnown == false` is reachable and means one thing.

**Steps.**
1. `probeVolumeCapabilities` — return `.unknown` when `resourceValues` fails.
2. `VolumeNamespaceCapabilities.init` — remove the `isKnown: Bool = true` default
   so every construction states it.
3. Collapse the two "unknown" representations to `VolumeNamespaceCapabilities.unknown`;
   the database loader returns exactly that value when either column is NULL.
4. Either probe `prefersDecomposedUnicode` or rename it to what it is. Record the
   decision and its evidence in `docs/research/`.

**Verify.** A test proves a failed probe yields `isKnown == false`, and that a
NULL-capability row and `.unknown` produce identical `FilesystemNameKey`s for an
accented path.

**Rollback.** Revert; capability columns are unchanged.

### Increment 6 · Delete what nothing uses

**Goal.** No dead abstraction, no shim, one delete path.

**Steps.**
1. Delete `RootNamespace` and `OtosTests/RootNamespaceTests.swift`'s coverage of
   it, keeping the persisted-capability assertions by moving them onto
   `VolumeNamespaceCapabilities`.
2. Delete `CatalogPath.relativePathIfContained`; callers use `relativePath`.
3. Delete `PlanningFileFacts.isNamingFactSettled`; its call sites ask
   `namingFactState` directly.
4. Delete `MediaOperationPlanTotals.eraseCount` and its planner plumbing.
5. Delete both `.library` branches in `SourceEraser.delete` and `eraseSourceFile`,
   and route `eraseSourceFile` through `SourceEraser` so its sole-owner comment
   is true.
6. Remove the `runID: String = UUID().uuidString` default on
   `MediaImportExecutor.execute`.
7. Comment `FilesystemNameKey.==`/`hash` with why byte-exact comparison is
   deliberate.

**Verify.** `script/verify.sh` green; no behavior change expected, so every
existing test stays green unmodified.

**Rollback.** Revert.

### Increment 7 · Documentation closure

**Goal.** The registry describes what is implemented.

**Steps.**
1. `docs/requirements.md` APP-032 — reconcile with the erase behavior increments
   3 and 6 actually land.
2. `docs/adr/0015-observability.md` — record the constant subsystem and why.
3. `docs/adr/0026-settled-naming-and-card-erase.md` — record that a present
   capture wall is a terminal naming fact, and that a busy source namespace
   yields an incomplete erase rather than a failed import.
4. `docs/architecture.md` — update the `MediaImportExecutor` row.
5. Delete this plan and update `docs/plans/README.md`.

**Verify.** `script/requirements-authority-check.sh` and
`script/ci-text-hygiene.sh check`.

---

## Not in this plan

Splitting `CatalogStore` (7,055 lines across four files, 258 functions). Every
defect above is a *type* that permits a wrong value, not a file that is too long,
and increments 3 and 5 remove the defect class without moving a single owner.
Re-measure after increment 6 before considering structural work.
