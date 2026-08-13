# Plan 0089 — Real Behavioral Proofs

## Goal

Pay down the verification debt that plans 0087 and 0088 leave behind, by writing
tests that assert the clauses the rows actually claim. This is the work plan 0082
described and did not do.

Scope is **new tests plus the `Tested by` rows they close**. No production
behavior changes. Depends on 0085 (suite can run), 0086 (green means something),
0087 (rows say what is really unproven), 0088 (absence rows are already closed by
guards, so this plan does not waste effort on them).

## Why now

After 0087/0088 the registry will carry an honest set of `unverified:` entries,
each naming a specific clause and the proof class it needs. That list is this
plan's backlog — and unlike 0082's, it will be accurate, because 0087 Stage 3
audits each row against its cited test bodies rather than assuming.

The one requirement that must not wait for that audit is MED-001.

## The flagship: MED-001, originals are read-only

MED-001 says: *"User originals shall remain read-only unless a future implemented
requirement explicitly changes that rule."* It is the product's central promise —
CLAUDE.md states it three times, and it is the reason Otos exists rather than
another library-vault app.

Its entire proof today is
`CatalogStoreTests#removeLibraryDeletesCatalogRowsAndLeavesOriginalsUntouched`,
which adds one library containing one file, removes the library, and checks the
file still exists. Every other path that touches the filesystem — import,
reorganization, enrichment, thumbnail generation, materialization, companion
inventory, camera staging — is unproven against this invariant.

A sampling test cannot fix this. The right shape is a **tree-invariant harness**:

```
Given a temp library root populated with a known fixture tree,
When any catalog operation runs to completion,
Then every path under that root has identical
     (existence, size, mtime, mode, inode, content hash)
     as before the operation.
```

`inode` matters: a copy-then-replace that preserves size and mtime still breaks
the promise, and only the inode shows it. `mode` catches a permissions change.
Content hash catches an in-place rewrite that preserves the stat block.

The harness snapshots the tree, runs the operation, snapshots again, and diffs.
The operations to cover, one test each:

| Operation | Entry point |
| --- | --- |
| add library + full scan | `CatalogStore.addLibrary(url:)` |
| rescan after external change | scan cadence / FSEvents injection |
| enrichment (metadata, thumbnail, hash) | `EnrichmentCoordinator` + `MediaEnricher` |
| materialization of a dataless original | `MaterializationCoordinator` |
| companion inventory | scan with `.xmp`/`.srt` present |
| remove library | `CatalogStore.removeLibrary(path:)` |
| import **from** a removable source | `MediaImportExecutor` — source tree unchanged unless `deleteSourceAfterImport` |
| loupe/compare preview decode | `PreviewImageLoader`, `VideoPreviewLoader` |

Two deliberate exceptions, asserted rather than excluded:

- **Import with `deleteSourceAfterImport = true`** — the user opted in. The test
  asserts exactly the imported sources disappear and nothing else changes.
- **Library reorganization** — an explicit user-initiated move. The test asserts
  every file is accounted for at its new path with the same inode and content
  hash, and no bytes were rewritten.

Those two are where the promise is most likely to break, so they get the
strictest assertions rather than an exemption.

This closes MED-001 and materially supports ARC-018 and G5 from plan 0088.

## Root cause of the wider debt

Rows were written with four to six `Given` clauses and closed against the one
happy-path test that existed. The acceptance examples were treated as prose
rather than as a checklist. The method below makes the checklist explicit.

## Method — apply per row, no exceptions

1. Copy the row's `Acceptance example` into the PR description and split it into
   numbered `Given` clauses.
2. For each clause, name the test that asserts it. If none, write it.
3. Name each new test after the clause, not the mechanism, so the citation is
   self-describing: `staleScanSuppressesMissingRowDeletion`, not `testScan3`.
4. A clause that is genuinely not machine-checkable keeps a bounded
   `unverified:` naming *that clause alone* — never the whole row.
5. Every new test must fail if the behavior is removed. Prove it: break the
   production code, watch it go red, restore. Record that in the PR. This is the
   single check that would have caught every tautology in the 0082 closure.

Step 5 is the plan's core discipline. A test nobody has watched fail is a
hypothesis.

## Stages

Batches follow 0087 Stage 3's audit output. Sizes are estimates; the audit sets
the real ones. One PR per batch, each independently mergeable and green.

### Stage 1 — MED-001 tree-invariant harness

Build `OtosTests/OriginalsReadOnlyTests.swift` plus a
`FilesystemTreeSnapshot` helper (path → existence, size, mtime, mode, inode,
XXH3 digest; reuse `ContentHasher`). Cover the eight operations and the two
opt-in exceptions above.

Start with `addLibrary` + scan, the simplest, to settle the harness API. Then
enrichment, which is where an accidental write is most likely (thumbnail
generation writing beside the original is the classic bug this catches).

Verification: temporarily make `MediaEnricher` write a `.thumb` file beside an
original; the harness must fail naming the exact path. Revert.

### Stage 2 — Import and reorganization under the harness

The two opt-in exceptions. Highest blast radius, most valuable assertions.

For reorganization, assert inode preservation explicitly — a same-volume move
must not copy. That is both a correctness and a data-integrity claim, and it is
what distinguishes a move from a copy-and-delete that could lose data on
interruption.

### Stage 3+ — The audited backlog

One batch per ~8 rows, ordered by blast radius: catalog/store truth first,
enrichment second, UI surface last. Each batch applies the five-step method.

Rows whose remaining debt is a UI-visual clause (paint, layout, animation) that
genuinely cannot be asserted headlessly keep bounded `unverified:` naming the
visual clause. That is an honest end state, not a failure — AGENTS.md's DoD
explicitly allows recording a limitation the agent environment cannot check.

## Verification

- `bash script/verify.sh` green after every batch.
- Every new test has a recorded "watched it fail" note in its PR.
- No `#expect(true` anywhere in `OtosTests/` (enforced by 0087's hygiene check).
- The registry's verified count rises only as real tests land, and every
  remaining `unverified:` names one specific clause.

## Non-goals and guards

- Do not re-cite an existing test to close a clause without reading its body and
  confirming it asserts that clause. That is the exact failure this plan exists
  to undo.
- Do not target a verified count or a deadline for reaching one. The count is an
  output.
- Do not write a test whose assertions cannot fail. If you cannot construct a
  code change that turns it red, it is not a test.
- Do not fold absence invariants back into unit tests — plan 0088's guards own
  those.
- Do not add scale machinery or performance assertions here. Correctness only;
  AGENTS.md requires measurement before optimization.
