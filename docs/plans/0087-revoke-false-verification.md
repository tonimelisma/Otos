# Plan 0087 — Revoke The False Verification Closure

## Goal

Make `docs/requirements.md` honest again, and make the gate that guards it check
*proof*, not *citation syntax*. The registry currently reports 96/96 requirements
verified and 0 unverified. That number is false, and the registry is now less
trustworthy than when it openly said `unverified:` on 73 rows.

Scope is **the registry, the gate, and the tests that falsely back it**. No
production behavior changes. Depends on plans 0085 and 0086 (a claim of "verified"
means nothing while the suite cannot run or cannot be trusted).

## Why now

Plan 0082 set out to close 73 `unverified:` rows and stated its own guard:

> A bandaid fix would be to delete the `unverified:` suffix and leave the existing
> single test as the whole proof... This plan forbids them: a row is verified only
> when a test exists whose name is cited as `path#symbol` **and whose body actually
> asserts the clause** named in the `unverified:` reason.

> Do not bulk-remove `unverified:` in one commit. Each batch is one PR with paired
> test + `Tested by` update.

What actually landed, `045812e` (#197) through `81ef6d2` (#245): 45 PRs, 73 rows
closed, **5 new test files totalling 283 lines**, and 40 of those 45 PRs touching
`docs/requirements.md` and nothing else. The mechanism was to replace a bare file
citation plus `unverified:` with three to five `#symbol` citations pointing at
tests that already existed and were written for other purposes.

## Root cause

`script/requirements-authority-check.sh` validates the **grammar of a citation**,
never the **semantics of a proof**. Its strongest check is
`:169` and `:171`:

```bash
if ! grep -Eq "func[[:space:]]+$test_name[[:space:]]*\\(" "$test_file" 2>/dev/null; then
  fail "requirement $id names missing Swift test $token"
fi
```

A cited symbol needs only to *exist*. Nothing ties it to the requirement. So there
are two ways to turn a red row green without proving anything:

1. **Re-cite an unrelated existing test.** Free — the repo has 646 tests, and some
   symbol in some file will always exist.
2. **Write a test that cannot fail.** Also free.

Both were used. This is Goodhart's law applied to a verification gate: the measure
became the target, and the measure was never proof.

The deeper design error is that the gate recognises exactly one proof class
(a Swift test symbol) while the registry contains at least three kinds of claim.
36 of 96 rows are **absence invariants** — "shall not", "shall never", "out of
product scope", "zero". No unit test can prove an absence. Faced with a row that
unit tests structurally cannot verify, and a gate that accepts any existing
symbol, the cheapest honest-looking move is a tautology. The repo already solved
this once and forgot: `script/check-no-unchecked-sendable.sh:2-4` says so in its
own header.

> ARC-042: zero unsound Sendable escapes in app and test sources. This exists
> because the requirement was verified by the string `manual:` for its whole life
> and drifted from 0 to 14 without one failing gate.

That is the correct pattern, already in the repo, already cited as ARC-042's proof
(`script/check-no-unchecked-sendable.sh#self-test`), and it was not reused.

## Inventory

### A. Rows backed by tests that cannot fail — provably false (10 rows)

Five test files, 15 tests, 283 lines. Six tests assert a literal `#expect(true, …)`;
the rest assert that a struct returns the values just passed into it, or that two
enum cases differ.

| File | Tests | What the bodies actually assert |
| --- | --- | --- |
| `OtosTests/AppBoundaryAndAlertTests.swift` | 4 | `swiftUIMainWindowIsSingleWindow` is `#expect(true, "SwiftUI is the UI framework")`. `appRunsUnsandboxedWithNormalFilesystemPaths` builds a `LibraryRootPath` and asserts `rawValue == "/Users/test/Library"` — nothing reads entitlements. The two eject tests assert enum cases carry their payloads and that `.busy != .ejected`. |
| `OtosTests/SidebarAndWindowTests.swift` | 4 | Three are `_ = SomeType.self` + `#expect(true, …)`. The fourth asserts `SidebarSelection.allMedia == .allMedia`. |
| `OtosTests/SettingsAddRemoveTests.swift` | 2 | Both `#expect(true, …)`. |
| `OtosTests/CatalogStateNamingTests.swift` | 2 | Constructs `CatalogWindowState`, asserts the fields hold the values passed in, and asserts `1 != 2`. |
| `OtosTests/CatalogDomainIdentifierTests.swift` | 3 | Asserts `rawValue` round-trips and that `Hashable` works. `storeBoundaryRequiresTypedIdentifiers` starts a real `CatalogStore` and then asserts nothing about it. |

These are worse than no test. `mainWindowIsSingleWindowNotWindowGroup` stays green
forever, including after someone changes `Window` to `WindowGroup` — the exact
regression ARC-014 exists to prevent, and the exact reason CLAUDE.md calls one
main window "a permanent product invariant".

Rows resting on them: **ARC-001, ARC-002, ARC-008, ARC-011, ARC-012, ARC-013,
ARC-014, ARC-015, APP-003, APP-008.**

### B. Rows whose cited tests do not touch the requirement — confirmed by reading (5 rows)

| ID | Requirement, abbreviated | Now cited | Why the citation is false |
| --- | --- | --- | --- |
| ARC-002A | `script/smoke-run.sh` shall never terminate an in-flight import; reads journals via `sqlite3 -readonly`; any sqlite error counts as busy | `MediaImportExecutorTests#journalRoundTripsThroughStore`, `#journalMutationWithMissingRowThrows`, `ReorganizationExecutorTests#journalRoundTripsThroughStore` | **No cited test executes `script/smoke-run.sh`.** The requirement is about the shell script's busy predicate and its `kill` refusal; the tests cover the Swift journal round-trip. Highest severity in this set: a regression kills the user's app mid-import. |
| APP-001 | Documentation shall claim only behavior proven by current source and tests | `CatalogStoreTests#addLibraryScansRegularFilesAndReloadsFromDisk`, `SidebarSelectionPolicyTests#showsAllMediaRequiresTwoFixedLibraries`, `CatalogProjectionTests#windowStateSortsLibrariesAndAssets` | A scan test cannot prove a claim about documentation. Plan 0082 explicitly ruled this row `unverified: bounded` and called that acceptable; it was closed anyway. |
| MED-001 | User originals shall remain read-only | `CatalogStoreTests#removeLibraryDeletesCatalogRowsAndLeavesOriginalsUntouched` + 2 | Proves one path (`removeLibrary`) leaves one file intact. Says nothing about import, reorganization, enrichment, thumbnailing, or materialization — every other path that touches the filesystem. This is the product's central promise. |
| MED-004 | Otos shall never add audio-specific playback, metadata, thumbnails, icons, classification, or workflows | `MediaEligibilityTests#catalogMediaExcludesNilPlainTextAudioAndDocuments` + 1 | Proves audio files are not catalogued. Does not prove the absence of audio *workflows* anywhere in 32k lines. |
| ARC-035 | Media metadata (byte-reading) is distinct from filesystem facts (readable without materialization) | `MediaEligibilityTests#catalogMediaIncludesImageAndMovieTypes` + 2 | Cited tests cover eligibility and scanning; the distinction the row draws is not asserted. |

### C. The remaining re-cited rows — audited, not assumed (≈58 rows)

The other rows closed in #197–#245 were re-cited the same way, but this plan does
**not** assert they are all false: some re-citations are probably sound, because
the tests named do exist and some genuinely cover the clause. They need an audit
with a stated method (Stage 3), not a blanket reset. Saying "all 73 are false"
would repeat the sin of the closure in the opposite direction.

## The fix: three proof classes

Every row is proven by exactly one of:

| Class | Grammar | Proves | Example |
| --- | --- | --- | --- |
| **Behavioral test** | `` `OtosTests/X.swift#testSymbol` `` | Positive behavior: given input, observable output | `CatalogStoreTests#addLibraryScansRegularFilesAndReloadsFromDisk` |
| **Structural guard** | `` `script/guard-x.sh#self-test` `` | Absence/structure across the whole tree | `check-no-unchecked-sendable.sh#self-test` (ARC-042) |
| **Bounded debt** | `unverified: <specific clause> — <why not yet machine-checkable>` | Nothing, honestly | plan 0082's original intent |

A row may cite several entries of the first two classes. `manual:` stays
forbidden. The registry's own column legend (`docs/requirements.md:18`) still
advertises `manual: <how>` and must be corrected — that legend is why `manual:`
kept reappearing.

## Stages

### Stage 1 — Delete the tests that cannot fail, reset their rows

- `git rm` all five files listed in Inventory A.
- For each of ARC-001, ARC-002, ARC-008, ARC-011, ARC-012, ARC-013, ARC-014,
  ARC-015, APP-003, APP-008, set `Tested by` to a bounded debt entry naming the
  clause and the proof class it will get, e.g.:

  ```
  unverified: singleton SwiftUI Window vs WindowGroup not machine-checked — needs structural guard (plan 0088)
  ```

- Fix `docs/requirements.md:18` to describe the three classes and drop the
  `manual: <how>` legend.

After this stage the registry reports 10 unverified rows and that is an
improvement, not a regression. Say so in the PR.

Verification: `bash script/requirements-authority-check.sh check` clean;
`bash script/verify.sh` green; `grep -c 'manual:' docs/requirements.md` returns 0.

### Stage 2 — Teach the gate to reject what it just accepted

Add to `script/requirements-authority-check.sh`, each with a self-test fixture
alongside the existing 14 (`:200-330`):

1. **Reject tautological proofs.** For every cited `OtosTests/…#symbol`, extract
   the function body and fail if it contains no assertion other than
   `#expect(true`, or contains no `#expect`/`#require`/`Issue.record` at all.
   Fixture: a test whose body is `#expect(true)` must fail the check.
2. **Reject shared-symbol citations across unrelated rows.** Warn when one test
   symbol is cited by more than N rows (start at N=6, tune from the real
   distribution). A single test proving eight different requirements is the
   signature of re-citation. Report, do not fail, in the first iteration.
3. **Recognise the guard class.** `script/*.sh#self-test` is already accepted by
   `:172-176`; add a self-test fixture pinning that behavior so it cannot regress.

Do not attempt to check that a test *semantically* matches its row — that is not
mechanisable, and pretending otherwise recreates the original error. The gate's
job is to make the cheap dishonest moves expensive; a human reviewer and the
Stage 3 audit do the rest.

Verification: `bash script/requirements-authority-check.sh self-test` clean with
the new fixtures; running check against the pre-Stage-1 `requirements.md`
(`git show d7f8680:docs/requirements.md`) must now **fail** on the deleted files'
citations. That is the regression proof this stage exists for.

### Stage 3 — Audit the ≈58 remaining re-cited rows

One PR per 10 rows. For each row, in the PR description, record a three-line
verdict:

```
ARC-046 | clause: "unreadable destination folder blocks instead of copying"
        | cited: MediaTransferPlannerTests#unreadableDestinationFolderBlocksInsteadOfCopying
        | verdict: SOUND — test name and body assert exactly this clause
```

Verdicts are `SOUND` (keep the citation), `PARTIAL` (keep the citations that hold,
add `unverified:` for the clauses that do not), or `FALSE` (reset to
`unverified:` naming the clause and the proof class needed).

Method, applied per row, no exceptions:

1. Read the row's `Requirement` and `Acceptance example`. List each `Given` clause.
2. Open each cited test and read the body — not the name. A name that matches the
   clause while the body asserts something else is the failure mode to catch.
3. Map clause → citation. Any clause with no citation whose body asserts it gets
   an `unverified:` entry naming that clause.
4. If the clause is an absence ("shall not"/"never"/"zero"), it cannot be closed
   by a unit test at all — mark it for a guard script in plan 0088.

Rows in Inventory B (ARC-002A, APP-001, MED-001, MED-004, ARC-035) are already
adjudicated `FALSE`; reset them in the first PR of this stage without re-auditing.

Expected outcome: a registry where the verified count is lower than 96 and every
number in it is true. Do not target a count.

## Verification

- `bash script/verify.sh` green.
- `grep -c 'manual:' docs/requirements.md` → 0.
- The new gate fails against `d7f8680`'s registry.
- No test in `OtosTests/` contains `#expect(true` — add this to
  `script/ci-text-hygiene.sh` so it cannot come back.

## Non-goals and guards

- Do not restore a `manual:` escape hatch or grow `ALLOWLIST` past 0.
- Do not delete a requirement row to avoid proving it. Rows describe implemented
  behavior; the behavior exists whether or not the proof does.
- Do not write a replacement test in this plan. Deleting a false proof and writing
  a real one are separate reviewable acts — plans 0088 and 0089 own the real ones.
- Do not treat a falling verified-count as a regression to be minimised. An honest
  60/96 is worth more than a false 96/96.
- Do not add source-text substring **tests** (AGENTS.md forbids). Structural
  guards are **scripts** under `script/`, which is the established, permitted
  pattern (ARC-042).
