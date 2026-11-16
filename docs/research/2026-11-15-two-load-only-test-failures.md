# Two load-only test failures, and what sat beside them

Date: 2026-11-15. Context: another agent's reproduction loop (tree c9c6e2a7..5fde6f83)
saw two tests fail under parallel load, each passing alone:
`MediaOperationCoordinatorTests/aPlanProvenBeforeNewPendingRowsIsNotHeldThroughTheMetadataWait`
and `CatalogProjectionShownFirstTests/anExpansionIsPublishedInTheStepThatAppliesIt`. That loop's
logs were gone, so neither failure's issue text was available. This pass reproduced what it
could, starting from `origin/main` 992b0b14.

## Method

- **Targeted repetition.** Each test ran 150 times in parallel in one process through a local,
  uncommitted `@Test(arguments: 0 ..< 150)`, in scoped `script/check.sh --only` runs.
- **Under the full suite.** The same 150-run copies ran inside full `script/check.sh` passes,
  beside another agent's scoped checks.
- **Probes.** Temporary expectations recorded what the test could see at the point in question.
  None is committed.

## The expansion test: a read in a later hop

The test applies an expansion and then, in a separate hop to Projection, expects
`publicationCount == published + 1`.

- **What a probe showed.** An expectation added after the expansion's pass settled
  (`waitForProjectionQuiescence`) found the count past `published + 1` in 42 of 150 runs.
- **What published again.** A second probe compared the last two recorded states field by field.
  In 51 of 54 runs that differed only in `duplicates`, and in 1 only in `people`. The Duplicates
  and People owners publish their groups on their own schedule; the pass the expansion rings
  hands them the new window, and they publish after it.
- **Why the test usually passed.** The test's next hop to Projection usually beats those
  publications. Under load it need not, and the count then reads `published + 2`.

So "published in the step that applies it" is guaranteed by the product. The intent is applied
synchronously in `CatalogProjection.apply`, and `showExpansion` publishes before it returns. The
test's way of reading that was only usually true. It now counts on Projection itself around the
intent, in one actor step (`CatalogProjection.publications(applying:)`, a test-target extension).
The same 150-run copy then passed 150 of 150 in a scoped run and in a full-suite pass.

The test still asserts what the code does since #787. The expansion is published from the held
collapse (`PhotoStackCollapse.changingExpansion`, `content.edited`), with no order read. The
On This Day cap path does not apply to a library scope.

## The metadata-wait test: not reproduced

| Run | Copies | Failed |
| --- | --- | --- |
| Scoped, `MediaOperationCoordinatorTests`, beside nothing | 150 | 0 |
| Full suite pass, beside another agent's scoped checks | 150 | 0 |
| Scoped, with a probe at the first wait | 150 | 0 (the probe's own records only) |
| Scoped, nine suites, after the changes here | 150 | 0 |
| Scoped, product files of `origin/main`, tests here | 150 | 0 |

- **What the probe showed.** When the test first saw `.waitingForMetadata`, the count was always
  1 of 2. That is the new wait, not an older one. The card was still `.scanning`, the read the
  file event started, in all 150. The coordinator was not yet quiescent in 134.
- **What was ruled out.** Reading the code found no path to `.ready` while the second row is
  pending:
  - A build whose snapshot holds the pending row parks the session, and parking drops the held
    plan.
  - A build whose snapshot predates the row is stale by its revisions, or it is applied and then
    replaced by the row's own rebuild before the test's first wait can pass.
  - A plan built while the card is read is never offered (`builtFromSettledSource`).
  - #785's counter only adds a rebuild, which ends in the same wait.
  - The retry's first frame is a building frame, which shows the held count, so `sawCount` holds.
- **What was not ruled out.** A hang in a wait the failure did not name.

## Found beside it: a count from before a plan, shown after it

- **The defect.** `ImportSessionMachine.SourceSession` held three separate "last proven" answers:
  - `lastReadyContext`, the held plan;
  - `settledOutcome`, the last run's outcome;
  - `lastNamingProgress`, the last naming count.
- **How it showed.** A plan proven after a metadata wait cleared none of the count. The
  coordinator's interim state tried the plan, then the settlement, then the count. So while the
  card was read again, the held plan could not be offered (`ImportSourceReadiness` not ready).
  A rebuild then fell through to the count from before the plan, and the bar drew "Checking the
  card… 0 of 1 items" about a card whose every row had been read.
- **The change.** One field, `lastProven: ProvenAnswer` (`.plan`, `.settled` or `.namingCount`),
  so each proof replaces the one before it. A held plan that cannot be offered now shows nothing
  in its place (`.planning`).
- **The test.** `aRebuildWhileTheCardIsReadAgainShowsNoCountFromBeforeItsPlan` delivers the
  rebuild at that point:
  - the card's read is held at a gate;
  - the rebuild is held in `ControlledImportPlanBuilder`.

## Sweep

**Recorders read after an act without waiting for the publication:**

- **The shape.** A test waits for Projection to be quiescent and then reads its recorder's last
  value. The recorder takes each state on a task of its own, so a quiescent Projection can have
  published a state the recorder has not appended.
- **The change.** `waitForProjectionQuiescence(_:recordedBy:)` waits until the recorder holds
  `CatalogProjection.lastPublishedState`. These now use it:
  - `CatalogProjectionShownFirstTests` (choices);
  - `CatalogProjectionTests` (hide, superseded builds);
  - `ProjectionEnrichmentCoalescingTests` (the `publish` helper, two window builders and both
    returns to All Media);
  - `ProjectionEnrichmentScaleTests`;
  - `PhotoSearchIndexTests` (`showRedSearch`).
- **The two returns to All Media.** They also drop what precedes their first All Media
  publication, since Duplicates and People can publish the library's window after it was
  counted.
- **The coordinator's progress test.** `MediaOperationCoordinatorProgressTests` read its recorder
  after the coordinator was quiescent. It now waits until the recorder holds what the coordinator
  presents.

**Identities from the wall clock:**

- **`ImportBatchID()`.** It was the start time in milliseconds, so two cards whose imports start
  in one millisecond shared a batch. Each run is keyed on it: the coordinator's `executions`, the
  catalog's `import_batch_unix_ms`, and the Imports sidebar row. It now takes its value from
  `UnixMillisecondIdentity.mint()`, which `MediaTrashBatchID()` shares: the time, or one past the
  last identity minted when the clock has not moved past it.
- **The plan's batch.** `MediaOperationMode.import` carried a second `ImportBatchID()`, minted on
  every re-plan and read by nothing. It is removed.
- **What else was checked.** Nothing else in product code derives an identity from the time.
  - Stack key stamps are times compared within one stack's command.
  - `RunContext.sessionID` carries the process ID.
  - Reorganization keys and staging names use UUIDs or catalog paths.

## Residual risk

- **The metadata-wait failure's cause is unknown.** Its text was lost. If it recurs, the
  `op=test.failure` line names the expectation, and the stall report names a hang.
- **A clock moved backward.** It could mint a batch equal to one from an earlier process.
  `UnixMillisecondIdentity` guards only within one process.
- **Lossy streams.** `MediaOperationCoordinatorProgressTests` still expects the recorder to see
  `.executing(progress: last)`. The presentation stream keeps only the newest value, so a recorder
  held off the CPU for the whole run could miss it. This was not observed.
