---
name: otos-review
description: Otos's review bar for a diff — lens A (implementation fidelity) and lens B (architecture), with the questions no lint can ask. Use for self-review before opening any PR and when reviewing someone else's.
---

# Reviewing an Otos diff

Review from the diff, not the author's intent. Rank findings by severity, each a concrete
failure scenario with `file:line`.
- A confirmed correctness bug, or a lost invariant or requirement, blocks merge.
- Smells and lens-B notes are logged on the PR.
- For a user-facing surface, also run lens C (`.claude/rules/ui.md`).

## Lens A: implementation fidelity

- Establish the oracle first:
  - Behavior-preserving work keeps existing tests green *unmodified*, plus a runtime
    differential where useful.
  - A bug fix reproduces, then verifies.
  - An invariant gets an adversarial pass: can I construct a violation?
- Diff against the plan, check the blast radius, and run every check you own. Then
  invert every "this is fine."
- For each `await` in the diff: what can change here, and is it re-read before it is
  written?
- Three questions no lint can ask:
  - **Platform delegate methods and callbacks.** Is every report it can deliver either
    consumed or ignored with a stated reason? An empty method is a decision.
  - **Waits, retries and timeouts.** Does Otos itself hold the fact being waited out?
    Then its owner releases or reports it, and time is not used (ADR 0033).
  - **Names.** For each type, method or log `op=` the behavior change touches: does it
    still say what the code now does? A changed behavior renames itself.

## Lens B: architecture

- Is this the simplest correct design?
- Does each question have one owner?
- Would a blank-slate build arrive here, or is this a patch around a wrong boundary?
- Does the change keep a commit's check within five minutes (ADR 0044, item 13)?

## Smells to name

See `.claude/rules/swift.md`, "Code smells". Write `None observed` when that is true.
