# Plan 0001 — Documentation & Process Reset

> Non-authoritative plan. Delete this file when the work is fully done.
> Execution order: **first** — it changes the rules every later plan (0002–0007)
> works under, so none of them has to produce a per-increment spec or run the
> stale-document audit ritual this plan abolishes.

## 1. Problem

The repo's documentation is organized around *increments* instead of around
*current truth*, and the process exists largely to maintain that sprawl:

- **50 per-increment specs** in `docs/specs/` (0001–0051). They are historical
  narratives; git history already owns history. Their existence forces the
  "repository-wide stale-document audit" every increment.
- **`docs/requirements.md` is 155 lines / 103 rows, 71 of which are `FND-*`
  process meta-rules** ("agents shall restate requirements", "one DoD report",
  …) — process text masquerading as requirements. Only ~32 rows (APP/ENR/MED)
  describe the product.
- **7 process docs** (`docs/process/*`, 926 lines total) that agentic tools do
  not read — only `AGENTS.md` (CLAUDE.md is already a symlink to it) is
  reliably loaded. Verified against the AGENTS.md ecosystem guidance: agents
  read AGENTS.md; anything else must be explicitly pointed to from it, and
  "every line should contain information the agent cannot get from the code."
- **`docs/onboarding.md` is 643 lines** of prose that must be re-edited on
  every behavior change (a standing maintenance tax; it drifted from reality
  at least twice during recent increments).
- **6 test files assert on source *text*** (`String(contentsOf:)` + substring
  checks on `.swift` files). They break on harmless refactors (one broke when
  `selectSidebar` moved files) and penalize restructuring.
- **SwiftLint hard errors on size** (`file_length` error 800,
  `type_body_length` error 500) split cohesive types (six
  `CatalogWindowViewModel*` files exist mainly for this) while the actually
  oversized `CatalogStore` (2,912 lines) escapes because it is already
  fragmented. Industry practice: size limits should be soft warnings;
  cohesion, not arithmetic, sets boundaries.
- **A completed plan was never deleted**: `docs/plans/0030-*.md`.

Owner decisions driving this plan (2026-07-08):
- Requirements + ADR docs must be **MECE and not increment-tied**, with an
  identifier that maps each requirement to the code and tests implementing it.
- Keep: ADRs (justifying decisions actually made), `docs/research/` (all
  online research/POCs must be documented), plans (deleted when done),
  DoD reports (on the PR **and shown to the user in full**).
- Old code reviews are never stored in the repo.
- Process docs that only AGENTS.md-unaware humans would read are deleted;
  surviving rules move into AGENTS.md.

## 2. Target documentation taxonomy (MECE)

| Location | Owns | Lifecycle |
| --- | --- | --- |
| `AGENTS.md` | How to work here: commands, structure, style, boundaries, non-negotiable product principles, DoD definition. Points at everything below. | Living |
| `docs/requirements.md` | Current product/system behavior only. Stable IDs, each mapped to source files + tests. No process rows. | Living authority |
| `docs/adr/` | One architectural decision per file, justifying what was actually built. Superseded ADRs are rewritten or replaced, never appended as history. | Living (supersede) |
| `docs/research/` | Dated research passes, POCs, benchmarks, with sources and conclusions. | Append-only |
| `docs/plans/` | Active plans only. | Deleted when done |
| `docs/architecture.md` (new) | One-page current-state map: the dataflow diagram + layer-ownership table. Replaces onboarding.md. | Living |
| PR comments | DoD reports, code reviews. | Never in the repo tree |

Explicitly **gone**: `docs/specs/`, `docs/process/`, `docs/onboarding.md`,
`docs/templates/spec-template.md`, per-increment spec workflow, stale-document
audit ritual, code-comment audit ritual (replaced by the normal rule "comments
must be true"; enforced in review, not as a ceremony).

`docs/product/roadmap.md` stays as-is (non-authoritative idea pile, explicitly
allowed by the owner).

## 3. Work items

### 3.1 Rewrite `AGENTS.md` (641 lines → target ≤ 250)

Keep, verbatim or tightened:
- Non-negotiable product principles (filesystem is truth, originals read-only,
  no sidecars, overlay lifecycle, one window, no-blank-grid invariant,
  unsandboxed, no audio features, image/video only).
- Rob Pike rules ("measure before optimizing") — one short paragraph, not two
  restatements.
- Concurrency rules (Swift 6 strict, MainActor budget, actor ownership, no
  heavy work on main).
- Toolchain + commands: `brew bundle`, `script/verify.sh`, `script/logs.sh`,
  `script/profile.sh`, `script/smoke-run.sh`.
- Git/PR workflow: worktree per increment, conventional branch prefixes, PRs
  not direct commits, review-comment sweep of last 5 PRs, CI policy.
- **DoD definition** (single final report; merged + cleaned worktree/branches;
  verification agent-owned). Add the owner's rule explicitly: *the full DoD
  report is posted on the PR **and** sent to the user in full — never a
  summary with a link.*

Replace / new:
- **Documentation rules section** replacing the spec-driven-workflow section:
  - Requirements and ADRs are MECE current-state docs; every behavior change
    updates the affected requirement rows and ADRs *in the same PR*.
  - Plans go in `docs/plans/`, numbered, deleted when complete.
  - All research (web, POC, benchmark) is written to `docs/research/` with
    sources, in the same increment it informs.
  - Code reviews and DoD reports live on PRs only.
  - **Boundaries (guard-rails against regression of this plan):**
    - Never create `docs/specs/` or per-increment spec files.
    - Never add process-rule rows to `docs/requirements.md`.
    - Tests must assert observable behavior; tests that read source files as
      text are forbidden.
    - Size lint thresholds are warnings; do not split cohesive types to
      satisfy them, and do not re-add hard errors.

Delete from AGENTS.md: Definition-of-Ready checklist, spec content checklist,
three-alternatives mandate, requirement-capture write-back protocol
(FND-007/008/011 material — the owner's actual instruction is simply
"capture decisions in the right doc"), stale-document/comment audit sections,
the long DoD bullet list duplicated from dod-report.sh (point at the script).

### 3.2 Restructure `docs/requirements.md`

1. **Drop all process/tooling meta-rows.** FND rows that are process rules
   (FND-001…FND-016, FND-021, FND-022 and similar) are deleted; the few that
   still matter become AGENTS.md sentences. Keep architecture rows that
   describe the *product/system* (e.g. FND-017 SwiftUI-first, FND-018
   unsandboxed, FND-019 store ownership, FND-020 path identity) — renumber
   into an `ARC-*` prefix.
2. **Keep and regroup product rows**: `APP-*` (18), `ENR-*` (11), `MED-*` (3)
   stay, re-checked against current behavior while migrating spec content
   (§3.3).
3. **New row format** (the ID→code/tests mapping the owner asked for):

   ```
   | ID | Requirement | Acceptance example | Implemented in | Tested by |
   ```

   "Implemented in" lists the owning source files; "Tested by" lists test
   files (or `manual: <how>` when only manually verifiable). Type/Status
   columns are dropped — a row's presence means Current; retired rows are
   deleted (git history remembers).
4. **Extend `script/requirements-authority-check.sh`**: keep the existing
   authority checks; add a check that every path in "Implemented in"/"Tested
   by" exists on disk (simple loop over `rg -o` extracted backtick paths).
   This makes the mapping self-verifying in `script/verify.sh`.

### 3.3 Migrate then delete `docs/specs/` (50 files)

For each spec, its surviving content goes to exactly one place:
- **Behavior it introduced** → verify a requirement row exists (most already
  do — specs are cited in the Evidence column today); enrich the row's
  acceptance text where the spec was more precise.
- **Decisions it recorded** → ADR backfill (see §3.4).
- **Everything else** (alternatives narratives, DoR checklists, retirement
  proofs) → deleted; git history owns it.

Mechanical procedure (junior-friendly): process specs in numeric order; for
each, grep `docs/requirements.md` for its filename, move any unique acceptance
detail into the citing rows' new columns, then delete the file and remove its
`docs/index.md` entry. Batch into a handful of commits (e.g. 0001–0020,
0021–0040, 0041–0051).

### 3.4 ADR backfill (decisions currently only in specs)

ADRs exist to 0013. Verified gaps — decisions that live only in spec files
today and must be captured before the specs are deleted:

| New/updated ADR | Decision to capture | Source specs |
| --- | --- | --- |
| Amend `0006-catalog-grid-rendering.md` | No-blank invariant enforcement, structural-apply fallback policy, animation policy, zoom (3–9 columns, mutation-gate arbitration), model-owned selection (`GridSelection`, no `super.mouseDown`), thumbnail-face hit area | 0038, 0039, 0046, 0047, 0048, 0049 |
| New `0014-sidebar-selection-and-source-lifecycle.md` | `SidebarSelectionPolicy` (default/attach/removed rules, All-Media visibility), honest eject (quiesce ≠ hide; unmount-driven removal; `RemovableEjectOutcome`) | 0050, 0051 |
| New `0015-observability.md` | Written by plan 0003 (placeholder here; do not pre-write) | — |

Keep `docs/templates/adr-template.md`; delete `docs/templates/spec-template.md`.

### 3.5 Replace `docs/onboarding.md` with `docs/architecture.md`

New file, ≤ 150 lines: the §2 dataflow diagram, the actor table (who owns
what, and why it is an actor), the layer-ownership table ("changing what the
UI shows → Projection; changing what is stored → Store + migration; …"), and
pointers to ADRs. No narratives, no per-file tour (file guides in the code
already do that). Delete `docs/onboarding.md`; update every reference
(`AGENTS.md`, `docs/index.md`).

### 3.6 Delete `docs/process/` (7 files)

| File | Disposition |
| --- | --- |
| `development-workflow.md` (249) | Rules that survive → AGENTS.md §3.1; rest deleted |
| `code-review.md` (188) | Severity model + merge gate → short AGENTS.md subsection |
| `code-smells.md` (88) | The Swift/macOS smell list → AGENTS.md (it is genuinely useful and short) |
| `performance.md` (166) | Superseded by plan 0003's ADR + AGENTS.md command list |
| `instrumentation-review.md` (114) | Superseded by plan 0003 |
| `testing.md` (78) | Fold the narrow-boundary testing rule into AGENTS.md |
| `apple-docs.md` (43) | Keep only if `script/apple-docs.sh` needs it; else fold usage note into AGENTS.md |

### 3.7 Delete source-text tests (6 files)

`SourceHygieneTests.swift` (454), `BrowserDiagnosticsSourceHygieneTests.swift`,
`CatalogBrowserRemediationSourceHygieneTests.swift`,
`MediaGridZoomSourceHygieneTests.swift`, `SQLiteRetirementSourceHygieneTests.swift`,
`SmokeLibrarySeedingSourceHygieneTests.swift`.

Before deleting each, list what it asserts and either (a) drop it (most are
"file contains string X" process checks), or (b) port the genuine invariant to
a behavioral or compile-time form. Known genuine invariants worth porting:
- "SQLite rowid never leaks outside the Store" → access-control: the stored
  types live in `CatalogStorePersistence.swift` as `private`/internal already;
  add a behavioral assertion only if access control cannot express it.
- "Views do not call the database" → covered by review + architecture map;
  no test.
- The `GridColumnCount` 3–9 bounds → already covered by `GridColumnCountTests`
  behaviorally; delete the text greps.

**Creep guard:** add to `script/ci-text-hygiene.sh` a check failing CI when
`String(contentsOf:` appears in `OtosTests/` (one `rg` line, with an
allowlist for fixture loading if needed — current fixture loads use
`Bundle`/`Data(contentsOf:)`; verify before finalizing the pattern).

### 3.8 SwiftLint size limits become warnings

In `.swiftlint.yml`:

```yaml
type_body_length:
  warning: 400        # error: removed
file_length:
  warning: 600        # error: removed
```

Since `script/lint.sh` runs `swiftlint --strict` (warnings fail),
`--strict` must be replaced: run swiftlint normally and fail only on
`error:` severity output (drop `--strict`, keep exit-code check), otherwise
the warnings would still be hard gates. Verify no *other* rule regresses from
error to ignored by this change (line_length error 160 remains an error).

Then, optionally in the same PR, re-merge the artificial ViewModel split
*only if trivial* (SidebarPolicy + Query extensions back into the main file);
otherwise leave for plan 0004.

### 3.9 Cleanup of stale planning artifacts

- Delete `docs/plans/0030-toolbar-sort-filter-query-surface-plan.md`
  (completed; landed as specs 0030+ which are themselves being deleted).
- Rewrite `docs/index.md` for the new taxonomy (currently indexes all 50
  specs).
- `script/dod-report.sh`: keep; adjust any wording that references specs or
  the audits; add the "send the full report to the user" reminder to its
  output header.

## 4. Execution order within this plan

1. `.swiftlint.yml` + `lint.sh` change (unblocks everything, zero risk).
2. AGENTS.md rewrite (the new rules take effect).
3. requirements.md restructure + check-script extension.
4. ADR backfill (0006 amendment, new 0014) — *before* deleting the specs they
   draw from.
5. `docs/architecture.md`; delete onboarding.
6. Spec migration + deletion batches; process-doc deletion; index rewrite.
7. Source-text test deletion + CI creep guard.
8. Stale plan deletion.

Steps 1–2 and 3–8 can be two PRs if one becomes unwieldy; otherwise one PR
with clean commits per step is fine. Full `script/verify.sh` after every step
(step 7 changes the test suite — expect the test count to drop; that is the
point).

## 5. Acceptance criteria

- `docs/` contains only: `adr/`, `research/`, `plans/` (active only),
  `product/roadmap.md`, `architecture.md`, `requirements.md`, `index.md`,
  `templates/adr-template.md`.
- Every requirement row's "Implemented in"/"Tested by" paths exist
  (`script/requirements-authority-check.sh` enforces it; runs in verify.sh).
- No process-rule rows remain in requirements.md.
- `rg "String\(contentsOf" OtosTests/` → no selection/hygiene matches; CI
  guard in place.
- SwiftLint passes with size rules as warnings; `verify.sh` green.
- AGENTS.md ≤ ~250 lines and contains the boundaries section.
- No document anywhere instructs creating per-increment specs.

## 6. Risks

- **Losing a decision during spec deletion.** Mitigation: the ADR-backfill
  step runs first and each deletion commit names the specs it migrated.
- **Requirements rows drifting during the rewrite.** Mitigation: rewrite is
  mechanical (regroup + recolumn); behavior text changes only where a spec had
  more precise acceptance wording.
- **`--strict` removal hiding real problems.** Mitigation: `lint.sh` still
  fails on any `error:`-severity violation; warnings appear in output.
