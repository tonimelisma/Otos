# Active Plans

Plans 0085–0093 are complete and were removed when the implementation,
structural guards, behavioral proofs, and verification closure landed. 0092
(import screen redesign and design-system adoption) and its spun-off 0093
(grid day headers, DES-069/APP-030) are both fully landed.

- [0094 — Unhosted Test Bundle On An OtosKit Framework](0094-unhosted-test-bundle.md) —
  extracts `OtosKit` so `OtosTests` drops `TEST_HOST`, takes pure logic off the main
  actor, replaces `UserDefaults` with a storage protocol that is in-memory in tests,
  and deletes the leak-policing scripts. Evidence in
  `docs/research/2026-08-16-unhosted-test-bundle-capability.md`.
