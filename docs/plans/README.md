# Active Plans

Completed plans are removed after their implementation, documentation,
verification, and merge closure.

- [0097 — One Namespace Owner, And The Erase Manifest](0097-one-namespace-owner-and-the-erase-manifest.md)

  Seven increments finishing what plan 0096 designed but did not verify. 0096
  landed as a single commit rather than its thirteen planned PRs, and `main` is
  red on the one test its own APP-032 row cites. Increment 1 greens it: card
  erase currently deletes nothing on every root — a containment guard compares a
  path against a root string that already ends in `/` — and the erase set is
  built from plan dispositions rather than execution outcomes, so fixing the
  guard alone would delete the sources of copies that failed. The rest gives the
  three defect classes one owner each: namespace rules that belong to a root and
  are never defaulted (one comparison function today has four disagreeing sources
  for its input, and 25 call sites that default it), one path equality law
  (`MediaRelativePath` compares bytes while `FilesystemNameKey` compares
  canonically, though `nameKey`'s symmetric normalization masks it today), an
  erase manifest that is the same number in the confirmation alert and the
  completion line, and a single owner permitted to delete from a source root while
  holding its lease and journaling each item. Nothing is blocked: the four
  questions the plan opened with were withdrawn on 2026-08-21 after the discovery
  that should have preceded them, and the table records what closed each one.

Plans 0085–0096 are complete and were removed when the implementation, structural
guards, behavioral proofs, and verification closure landed. 0092 (import screen
redesign and design-system adoption) and its spun-off 0093 (grid day headers,
DES-069/APP-030) are both fully landed. 0094 (the OtosKit framework, the unhosted
test bundle, and the in-memory `PreferenceStore`) is fully landed — see ADR 0023
and `docs/research/2026-08-16-unhosted-test-bundle-capability.md` for the decision
and its evidence. 0095 (honest import — MTP correctness, one writer per published
fact, app-wide design system) is fully landed across twelve increments; ADR 0024
(readiness gate and single presentation writer) carries its architectural
decisions forward. 0096 (path equality, settled naming, honest progress) landed
its implementation in `40261bf` and its decisions in ADR 0025 and ADR 0026; plan
0097 carries the integration debt it left behind.
