# Active Plans

Numbered work plans. **Delete a plan when its work is fully done** (AGENTS.md).

## The current set, and why it is ordered this way

These six plans exist to restore one property: **a green `script/verify.sh` and a
row in `docs/requirements.md` should both mean what they say.** As of `d7f8680`
neither did — `verify.sh` exited 1 at lint and had not reached build or test for
~50 merges, and the registry reports 96/96 verified on the strength of tests that
cannot fail.

Two blockers were fixed while writing this set, because a red `main` blocks
everything else (AGENTS.md): `b72017a` restored lint green via `swiftformat .`,
and `e5c92ef` removed two self-recursive `async` test gates that grew a test host
to **57.3 GB** and prevented the suite from ever finishing. The suite now
completes at a 205 MB peak, 641 passed / 1 failed. The remaining failure is real
and owned by 0086.

The architecture is not the problem and is not being rebuilt. `docs/architecture.md`
describes a sound one-directional design with clear ownership; these plans keep it.

| # | Plan | Blocks on | Why it is here |
| --- | --- | --- | --- |
| 0085 | Close the gate that let `main` stay red | — | The red is fixed (`b72017a`, `e5c92ef`); the CI hole that hid it across ~50 merges is not. |
| 0086 | A test suite whose green means something | — | One real failing test remains (its assertion contradicts its harness), plus a resource ceiling so the next runaway allocation fails loudly. |
| 0087 | Revoke the false verification closure | 0086 | Delete tests that cannot fail, reset the rows resting on them, teach the gate to check proof rather than citation grammar. |
| 0088 | Structural guards for absence invariants | 0087 | 36 rows assert "shall never". Unit tests cannot prove absence; guard scripts can. The pattern already exists as ARC-042. |
| 0089 | Real behavioral proofs | 0087, 0088 | The work plan 0082 described and did not do — starting with MED-001, "originals are read-only", today proven by a single test. |
| 0090 | One owner for post-layout grid work | 0085 | Optional. Two hand-rolled copies of one mechanism; the second shipped untested on the no-blank invariant path. |

0085 → 0086 → 0087 is a strict chain: you cannot trust a verification claim while
the suite cannot run, and you cannot audit the registry while a green suite is
meaningless. 0088 and 0089 both depend on 0087's audit output. 0090 is
independent after 0085 and may be dropped.

## Superseded

- **0082** (requirement verification closure) — deleted in `d7f8680` as complete.
  It was not: its own guards against bulk-removing `unverified:` were violated by
  the increment that closed it. Plans 0087–0089 redo it honestly.
- **0083** (lint hygiene) — diagnosed `swiftlint` (which passes, 0 serious) rather
  than `swiftformat --lint` (which is the entire red). Replaced by 0085.
- **0084** (docs/architecture alignment) — genuinely complete; every inventory item
  D1–D6 verified done on `main`. Deleted.

## Writing a plan here

A plan is ready when a junior developer can execute it without discovering
anything. That means: the root cause is measured and quoted with `file:line`, the
inventory is complete rather than sampled, each stage is independently mergeable
and leaves `verify.sh` green, verification is a command with an expected output,
and the non-goals name the specific bandaids that would otherwise be tempting.

If a stage says "investigate", "check whether", or "as appropriate", it is not
ready.
