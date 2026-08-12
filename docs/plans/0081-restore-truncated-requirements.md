# Plan 0081 — Restore The Truncated Requirements Registry

## Severity

`docs/requirements.md` is, per `AGENTS.md`, "the authoritative registry of implemented
product/system behavior". **86 of its 96 rows currently contain requirement or
acceptance text that was mechanically truncated mid-sentence.** Roughly **32,588
characters** of requirement text were destroyed.

This is a documentation-integrity defect, not a formatting nit. The registry is the
document a reviewer consults to decide whether a behavior change is in scope, and
the document `script/requirements-authority-check.sh` enforces against. Right now
most of its rows stop mid-clause.

Nothing about product behavior is wrong. The *record* of it is.

## Evidence

Every truncated cell is **exactly 400 characters long and ends in a literal `...`**.
That is not coincidence: `script/requirements-authority-check.sh:90-94` rejects any
requirement or acceptance cell longer than 400 characters.

```
total requirement rows:                     96
truncated cells:                            86   (all exactly 400 chars)
characters of requirement text lost:     32,588
recoverable verbatim from 8810ac1:          86   (100%)
restored cells that still exceed 400:       86   (every one needs a real rewrite)
```

Introduced by a single commit:

| Commit | Truncated cells |
| --- | --- |
| `8810ac1` (parent) | 0 |
| **`639d12f`** — *docs: remove requirements allowlist and reconcile current truth (0079 Stage 6)* | **87** |

The 400-character cap was satisfied by cutting the text at 400 characters and
appending `...`, rather than by rewriting each requirement concisely. The same commit
also **stripped markdown backtick formatting** from identifiers, so restored text must
recover code spans as well as words.

Worked example — `ARC-002A`, already fixed in the increment that opened this plan:

- Original (`8810ac1`), 536 chars, complete, backticked.
- After `639d12f`, 400 chars, ending `...covers both journals with a global invariant (any row → neve...`.
- Now: 398 chars, complete, backticked, every fact preserved — including the two
  clauses truncation had removed (`per-root output is diagnostic only`;
  `is_import_active` aliasing `has_active_operational_work`).

That row proves the compression is achievable without loss. It took judgment, not a
character count.

## Why no gate caught this

Three independent gaps lined up:

1. **The checker measures length, never completeness.** A cell ending in `...` is
   indistinguishable from a finished sentence to `requirements-authority-check.sh`.
   Truncating to exactly 400 characters makes the check *pass*.
2. **The checker is locale-dependent.** `script/requirements-authority-check.sh:90`
   uses bash's `${#req}`. Under macOS's stock bash 3.2 with `LANG` unset, that counts
   **bytes**, not characters. Rows containing multibyte characters (`→ ∪ ↔ —`) are
   over-counted by 2-4, so `script/verify.sh` — whose *first* step this is — fails on
   a machine with no locale set and passes on one with `LANG=en_US.UTF-8`. The
   required local check is therefore not deterministic across environments.
3. **CI has not run.** Every recent run on `main` reports
   *"The job was not started because recent account payments have failed or your
   spending limit needs to be increased"* — a billing blocker, which is the one
   waiver condition `AGENTS.md` allows. `ci.yml:67` would have run the checker, but
   no job has started, so the remote gate has been dark.

Gap 1 is the one that let truncation look like a fix. Gap 2 is why the local signal
is untrustworthy. Fix both before restoring text, or the restoration cannot be
verified.

## Stages

### Stage 1 — Make the gate trustworthy

No content changes. Harden `script/requirements-authority-check.sh` first, so the
restoration in Stage 2 has a gate that can actually fail.

- **Locale determinism.** Force character semantics regardless of the caller's
  environment. Either export a UTF-8 locale at the top of the script, or count
  characters explicitly rather than relying on `${#var}` under bash 3.2. Add a
  self-test case (the script already has a `self-test` mode, `verify.sh:7`) covering
  a cell containing a multibyte character at exactly the boundary, asserting the
  result does not change with `LANG` unset vs. `LANG=en_US.UTF-8`.
- **Completeness rule.** Reject any requirement or acceptance cell that ends in `...`
  (or a Unicode ellipsis), with a message naming truncation explicitly and pointing
  at this plan. This makes the 86 existing rows go red — that is the point. Land
  Stage 1 and Stage 2 together, or land Stage 1 with the rule staged behind the
  restoration, so `main` is never knowingly left red.
- Extend the self-test fixtures (`:281`, `:290` already cover the overlong cases) with
  a truncated-cell fixture.

### Stage 2 — Restore and rewrite the 86 cells

For each truncated cell:

1. Recover the original from `git show 8810ac1:docs/requirements.md` — all 86 are
   present there verbatim, so no requirement has to be reinvented.
2. Rewrite it to fit 400 characters **without dropping a fact**. Restore backtick code
   spans on identifiers, paths, and symbols.
3. Verify each restored requirement against the source files the row already cites.
   Where the original text and the current code disagree, the code wins and the row
   records current truth — that reconciliation was `639d12f`'s legitimate purpose and
   must not be lost while undoing its truncation.

Work in reviewable batches by ID prefix, one PR each, so a reviewer can check
faithfulness against `8810ac1` per batch rather than reading an 86-cell diff:

| Batch | Cells |
| --- | --- |
| `ARC-003` … `ARC-026` | 19 |
| `ARC-031` … `ARC-053` | 23 |
| `APP-001` … `APP-023` | 22 |
| `ENR-001` … `ENR-015` | 22 |

**Do not** blanket-revert `639d12f`. That commit also removed the requirements
allowlist and reconciled genuinely stale rows; only its truncation is being undone.

**Do not** "fix" a row by raising the 400-character cap. The cap is a real constraint
that keeps rows reviewable, and `ARC-002A` demonstrates a 536-character requirement
compressing to 398 with every fact intact. If a specific row genuinely cannot be
expressed in 400 characters, that is a signal the row is doing two jobs and should be
split into two requirements — raise it in the PR rather than widening the limit.

### Stage 3 — Confirm

- `script/requirements-authority-check.sh` and its `self-test` green with `LANG`
  unset **and** with `LANG=en_US.UTF-8`.
- No cell ends in `...`; no cell exceeds 400 characters.
- `script/verify.sh` green.
- Re-run the audit used to open this plan and confirm `truncated cells: 0`.

## Verification helper

The audit that produced the numbers above, for re-running after each batch:

```bash
python3 -c "
import io,re
n=0
for line in io.open('docs/requirements.md',encoding='utf-8'):
    if not re.match(r'^\| [A-Z]{3}-[0-9]',line): continue
    for cell in [x.strip() for x in line.strip().strip('|').split('|')][1:3]:
        if cell.endswith('...') or len(cell)>400: n+=1
print('bad cells:',n)"
```

## Requirements and ADR impact

No product behavior changes, so no rows are added or removed and no ADR changes. This
plan restores the *text* of existing rows. Stage 1 changes a script, not a
requirement — `AGENTS.md` forbids process/tooling rows in `docs/requirements.md`.

## Done criteria

- All 86 cells complete, backticked, ≤400 characters, and faithful to `8810ac1`
  except where current code required reconciliation.
- The checker rejects truncation and is locale-deterministic, with self-test coverage
  for both.
- `script/verify.sh` green.
- This plan deleted once all three stages have landed, per `AGENTS.md`.
