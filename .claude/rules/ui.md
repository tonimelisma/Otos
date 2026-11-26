---
paths:
  - "OtosKit/Views/**"
  - "OtosKit/ContentView.swift"
  - "docs/design/**"
---

# User-facing surfaces: review lens C

`docs/design/design-system.md` is the authoritative registry of design rules. Its `DES-*`
rules are reviewed like requirements: a UI change that violates one either changes the
rule in the same PR or is wrong. Deviations from macOS defaults are marked `[deviation]`
there with their justification; do not add unmarked ones.

Run these five checks, in order, on any change to a user-facing surface:

1. Name the surface's single L1 primary fact (DES-010). If you cannot, stop: the surface
   is not designed yet.
2. Assign every string on it to a level (DES-010–013).
3. Check the zones and the fixed height across every state (DES-018, DES-053).
4. Look at it in light and dark (DES-022), then in grayscale (DES-029). From a cloud
   session that means CI's captures (`ci` skill), made gray in the session
   (`convert <png> -colorspace Gray <gray.png>`).
5. Tab through it with no mouse, and run it once with Reduce Motion on (DES-080,
   DES-075).

Cite the `DES-*` rules the change satisfies. When a `DES-*` rule becomes observable
behavior worth testing, add or update the `APP-*` row in `docs/requirements.md` and cite
the `DES-*` ID in its Requirement text. The design doc says what it should look like; the
requirement row says it is implemented and points at the test.

Views stay passive (AGENTS.md, "Architecture Standards"): `script/guard-view-passivity.sh`
checks it.
