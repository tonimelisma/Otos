# Active Plans

Plans 0085–0091 are complete and were removed when the implementation,
structural guards, behavioral proofs, and verification closure landed.

- [0092 — Import Screen Redesign And Design-System Adoption](0092-import-screen-and-design-system.md) —
  increments 0–6 landed: enforceable `DES-*` guards, the presentation-model gaps,
  user-ordered libraries and the deterministic import destination, the rebuilt
  import bar, and single-owner status. Increment 7 (grid day headers) is spun off
  into its own scoping plan.
- [0093 — Grid Day Headers](0093-grid-day-headers.md) — scoping document for
  DES-069: the per-asset date plumbing it needs, the open sort-order spec
  question, and the no-blank-invariant risk area, ahead of a full implementation
  plan.
- [0094 — Unhosted Test Bundle On An OtosKit Framework](0094-unhosted-test-bundle.md) —
  extracts `OtosKit` so `OtosTests` drops `TEST_HOST`, takes pure logic off the main
  actor, replaces `UserDefaults` with a storage protocol that is in-memory in tests,
  and deletes the leak-policing scripts. Evidence in
  `docs/research/2026-08-16-unhosted-test-bundle-capability.md`.
