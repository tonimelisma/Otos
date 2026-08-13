# Import Bar — Screen Spec

The bottom status surface shown for a selected removable source, and the same
surface while an import runs. Cites `docs/design/design-system.md` by ID; rules are
not restated here.

Owner: `Otos/Views/ImportPlanFooter.swift`. Presentation source:
`MediaOperationSourcePresentation`. Grid is unchanged — a card renders exactly like
a library (DES-065). Per-item import selection is out of scope: import imports all
new media.

Visual reference: `Otos Import.dc.html` in the design project (options `1a` today,
`1b` designed, `1c` states).

## Layout

One surface, fixed height across every state (DES-018, DES-053). Three zones,
left to right, `padding: 12 16`, column gap 28:

```
┌─────────────────────────────┬──│─────────────────────────────┬──────────────────┐
│ L1  42 new items · 68.2 MB  │  │ Copy into   [Summer Photos ⌄] │  ┌────────────┐  │
│ L3  139 already in your lib │  │ Afterwards  ☑ Eject  ☐ Erase │  │ Import 42… │  │
└─────────────────────────────┴──│─────────────────────────────┴──────────────────┘
   what                      hairline   choices                        the act
```

- **What** — L1 over L3, left-aligned, no icon in the ordinary case.
- **Choices** — separated by a `.5 pt` hairline, `padding-left: 12`. Two rows, both
  `.callout` labels in a fixed 66 pt label column (DES-016), controls at 22 pt.
- **The act** — one prominent 30 pt button, right-aligned, Return default (DES-052).

Zones never swap sides. The bar's height is set by the two-row choices block and
does not change when zones empty in other states.

## States

Five, per DES-030. The internal states in `MediaOperationSourcePresentation` map
onto them; none of the internal names is published.

| User-facing state | Internal states mapped | L1 | L3 | Middle | Action |
| --- | --- | --- | --- | --- | --- |
| **Preparing** | `inventory`, `waitingForMetadata`, `planning`, `needsReplan`, `queuedForReadiness` | `Looking through the card…` | `Checked 112 of 181 items` (omit if no honest denominator) | indeterminate bar, always moving | `Import` — visible, disabled |
| **Ready** | `ready`, `executionUnavailable` | `42 new items · 68.2 MB` | `139 already in your library` (omit at zero) | destination + afterwards controls | `Import 42 Items` |
| **Working** | `executing` | `Importing 12 of 42` | `19.4 MB of 68.2 MB · about 40 seconds left` | determinate bar; under it, `Into Summer Photos · the card ejects when it's done` | `Cancel` |
| **Done** | `completed` | ✓ `42 items copied and verified` | `In Summer Photos · card ejected — safe to remove` | empty | `Show These Items` |
| **Needs attention** | `ready` with a nonzero attention count | `39 new items · 61.0 MB` | ⚠ `3 items can't be read · Show them` | destination + afterwards controls | `Import 39 Items` |
| **Failed** | `failed` | `Couldn't finish the import` | what to do next, one clause | empty | `Try Again` |

Two Ready sub-cases:

- Nothing new — L1 `Nothing new on this card`, L3 `All 181 items are already in your
  library`, action `Eject Card`.
- Empty card — L1 `This card is empty`, action `Eject Card`.

## Copy

Rewrites of the current strings. Pattern per DES-034 through DES-039.

| Current | Replacement |
| --- | --- |
| `Waiting for metadata (12/139)` | `Looking through the card…` + L3 `Checked 12 of 139 items` |
| `Inventory…`, `Planning…`, `Source changed — replanning…` | `Looking through the card…` (one state; the cause is ours, not the user's) |
| `Import queued — finishing metadata…` | `Looking through the card…`, with the button showing a disabled queued state |
| `Importing 12/139` | `Importing 12 of 139` + L3 `19.4 MB of 68.2 MB · about 40 seconds left` |
| `12 copy · 4 preexisting · 3 companion · 1 blocked · 521 MB · 2 skipped packages` | `12 new items · 521 MB` + L3 `4 already in your library · 1 can't be read` |
| `Cleanup/eject withheld while blocked or skipped-package attention remains` | Nothing. The eject checkbox disables, tooltip: `Some items still need attention.` (DES-038) |
| `Sidecars on · Delete source after import · Auto-eject off` | Nothing. Inline controls state their own condition; the sidecar preference stays in Settings. |
| `Import queued (execution lands in a later update)` | Never shipped (DES-039) |
| `Import complete — nothing new` | `Nothing new on this card` |
| `Destination` | `Copy into` — it names what the control does, and the popup's value is a library, not a path |
| `Delete all 181 items from the card after importing` | `Erase the card` — the count is already on screen; `erase` is the platform's word for a card |
| `Eject the card after importing` | `Eject the card` — the "afterwards" label carries the timing |

## Ownership of status

One fact, one owner (DES-040):

- While the bar is visible for a source, the bar owns the operation's status and
  that source's sidebar row shows **no** indicator.
- When the selection moves elsewhere mid-import, the sidebar row shows a 32 pt
  determinate bar; that is the only place status appears then.
- When import starts and the view moves to the new import batch, the same bar
  travels with the operation, so there is still exactly one progress surface.

This is the change that removes the current duplication of an in-flight import
being reported in both the footer and the sidebar simultaneously.

## Destructive actions

`Erase the card` is the only destructive control on this surface. Per DES-027 and
HIG: unchecked by default regardless of the stored preference, and on a run where
it is checked, a completion-time alert with two verbs — `Erase Card` / `Keep Items`
— rather than silent execution from a sticky global toggle.

## Motion

Enter: slide up 24 pt with fade, 0.35 s spring (DES-071). State change: cross-fade
the left block, swap the right button in place, fixed height. Done: checkmark
scales from 0.6 with overshoot (DES-073), bar holds ~6 s, then leaves. All of it
collapses to a 0.15 s cross-fade under Reduce Motion (DES-075).

## Accessibility

Tab order is left to right: destination popup, eject, erase, primary button.
Return imports; Escape cancels during Working. The L1 line is a live region
announced on state change only (DES-083). The determinate bar exposes value and
total, not a synthesized percentage.

## Open questions for the owner

1. `Copy into` vs `Destination` as the label.
2. Whether erase moves entirely to a completion-time alert (Photos' model) and the
   pre-flight checkbox is dropped.
3. Whether the bar auto-dismisses on Done, or persists until the user navigates.
