# Active Plans

- **0095 — [Honest Import](0095-honest-import.md).** Camera (MTP) import has never
  worked end to end: the plan is built from persisted rows before the device is
  live, device inventory landing never triggers a replan, and the catalog stores a
  camera file's *creation* date under the field revalidation reads as its
  *modification* date. Twelve increments fix that, give every published fact a
  single writer, remove the fabricated progress/byte values, roll the design
  system out app-wide, and delete the remaining dead paths.

Plans 0085–0094 are complete and were removed when the implementation, structural
guards, behavioral proofs, and verification closure landed. 0092 (import screen
redesign and design-system adoption) and its spun-off 0093 (grid day headers,
DES-069/APP-030) are both fully landed. 0094 (the OtosKit framework, the unhosted
test bundle, and the in-memory `PreferenceStore`) is fully landed — see ADR 0023
and `docs/research/2026-08-16-unhosted-test-bundle-capability.md` for the decision
and its evidence.
