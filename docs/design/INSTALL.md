# How to install these docs in the Otos repo

Two files are ready to drop in:

| From this project | To the repo |
| --- | --- |
| `repo/docs/design/design-system.md` | `docs/design/design-system.md` |
| `repo/docs/design/import-bar.md` | `docs/design/import-bar.md` |

Nothing else needs to move. The visual mockups stay in the design project
(`Otos Import.dc.html`, `Otos Design Guidelines.dc.html`) and are referenced by
name from `import-bar.md`; the markdown is self-sufficient without them.

## 1. Make it discoverable to agents

`AGENTS.md` is what Claude Code reads first, so the design system has to be named
there or it will not be consulted. Add to the pointer paragraph near the top:

```md
`docs/design/design-system.md` is the authoritative registry of design rules for
user-facing surfaces; per-screen specs live beside it in `docs/design/`.
```

And add one bullet to **Non-Negotiable Principles**:

```md
- User-facing surfaces follow `docs/design/design-system.md`. Its `DES-*` rules are
  reviewed like requirements: a UI change that violates one either changes the rule
  in the same PR or is wrong. Design deviations from macOS defaults are marked
  `[deviation]` there with their justification; do not add unmarked ones.
```

## 2. Add it to the documentation map

In `docs/index.md`, alongside the existing entries:

```md
- `docs/design/design-system.md` — design rules for user-facing surfaces (DES-*).
- `docs/design/import-bar.md` — import status surface: layout, states, copy.
```

## 3. Wire it into the workflow you already have

Three mechanical hooks, in increasing order of effort:

**Definition of Done.** Add one line to whatever `script/dod-report.sh` checks or
prints: *"UI change: cites the DES-* rules it satisfies, and was reviewed in light
and dark."* That single sentence is what makes the document get read.

**Requirements cross-reference.** When a `DES-*` rule becomes observable behavior
worth testing — the five user-facing states, the copy strings, the single-owner
status rule — add or update the `APP-*` row in `docs/requirements.md` and cite the
`DES-*` ID in its Requirement text. The design doc says what it should look like;
the requirement row says it is implemented and points at the test.

**Grep guards.** Two cheap structural checks, in the spirit of
`script/requirements-authority-check.sh`:

- Forbidden vocabulary in user-facing strings (DES-035, DES-039): fail on `plan`,
  `disposition`, `companion`, `preexisting`, `blocked`, `inventory`, `replan`,
  `execution`, `queued`, `later update` inside a `Text(` or `LocalizedStringKey`
  literal.
- Color and font literals in views (DES-001, DES-020): fail on a hex or
  `Color(red:` literal, or a `.system(size:` call, under `Otos/Views/`.

Both are one-line `rg` invocations with an allowlist file, and they catch the two
regressions most likely to happen quietly.

## 4. What a design review looks like after this

For any change to a user-facing surface:

1. Name the surface's single L1 primary fact (DES-010). If you cannot, stop.
2. Assign every string on it to a level (DES-010–013).
3. Check the three zones and the fixed height (DES-018, DES-053).
4. Screenshot light and dark (DES-022), then grayscale one of them (DES-029).
5. Tab through it with no mouse, and run it once with Reduce Motion on
   (DES-080, DES-075).

That is five minutes, and it is the whole review.

## Keeping the two in sync

The markdown is authoritative; the `.dc.html` mockups are illustrations. When a
rule changes, change `design-system.md` first, then the mockups if they now
contradict it. If they ever disagree, the repo wins.
