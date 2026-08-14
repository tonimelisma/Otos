# HIG and Accessibility Validation — `design-system.md` v0.1

Audit of the drafted design rules against Apple's Human Interface Guidelines and
accessibility criteria, 2026-08-13. Each finding names the rule, the source, and
the correction. Corrections marked **applied** are already in `design-system.md`.

## Findings

### F-1 — Secondary label text fails the contrast minimum on light chrome (applied)

`DES-028` claimed secondary-on-bar clears 4.5:1 in both appearances. It does not.

Apple's own criteria: <cite index="16-8">most modern accessibility guidelines recommend a minimum contrast ratio of "4.5 to 1 between foreground text and its background"</cite>, with <cite index="16-11">3:1 commonly recommended for non-text contrast</cite>, and <cite index="16-9">if your app supports Dark Mode, be sure to check the minimum contrast in both light and dark modes</cite>.

Measured against the drafted surfaces:

| Text | Background | Ratio | Verdict |
| --- | --- | --- | --- |
| secondary 50% black | bar `#FBFBFC` | **3.9:1** | fails 4.5:1 |
| secondary 55% white | bar `#2A2A2C` | 5.4:1 | passes |
| tertiary 26% black | content `#FFFFFF` | **1.9:1** | fails 3:1 |
| tertiary 25% white | content `#1C1C1E` | **2.4:1** | fails 3:1 |

L3 is 11 pt — well under the 18 pt / 14 pt-bold threshold where <cite index="17-7,17-8">large text requires a minimum contrast ratio of 3:1</cite> — so the 4.5:1 rule applies to it in full.

This is not an Otos-specific defect; the system `secondaryLabelColor` behaves the
same way on a light window. But Otos's chrome is *lighter* than the system default
(DES-022), which makes it marginally worse, and the L3 line carries real
information — counts, remaining time — so it cannot be treated as decorative.

**Correction:** L3 uses 60% black on light chrome and 60% white on dark (5.7:1 and
6.0:1). L4 uses 45% (3.3:1 light, 4.4:1 dark). The tertiary level is reserved for
non-text elements — hairlines, disabled glyphs — where the 3:1 non-text rule
applies and the drafted values pass.

### F-2 — L4 was permitted to carry information it cannot legibly carry (applied)

`DES-013` allowed `.footnote` at tertiary for "metadata that is looked up". At
1.9:1 that text is not reliably readable by a low-vision user, which makes the
level dishonest rather than quiet.

**Correction:** L4 keeps its size but takes the 45% value from F-1, and DES-013
now states that anything a user may need to *read* — as opposed to notice the
presence of — is L3 or above.

### F-3 — Introductory label on the destination control is correct, and now justified (applied)

The draft used a `Copy into` label beside the destination control without citing a
rule, and HIG's push-button guidance points the other way: <cite index="1-1,1-2">avoid providing introductory labels. Push button titles should be descriptive enough that a label is unnecessary</cite>. That guidance is
about push buttons, not pop-up buttons, and applying it here would have been wrong.

For pop-up buttons HIG says the opposite: <cite index="2-1,2-2">give people a way to predict a pop-up button's options without opening it. For example, you can use an introductory label or a button label that describes the button's effect, giving context to the options</cite>. A library name alone — "Summer Photos" — gives no
clue that the menu contains libraries, so the introductory label is required.

**Correction:** DES-054 now names the control by its platform type and requires the
introductory label, citing this guidance. See `import-bar.md` for the label choice.

### F-4 — Progress rules match HIG; description rule tightened (applied)

`DES-031`, `DES-032`, `DES-072` align with HIG's progress guidance as recorded in
`docs/research/2026-08-09-import-ux-benchmark.md` §3: prefer determinate; keep
indicators moving; display a description only when it adds context; be accurate and
succinct; avoid vague terms like *loading*; let people cancel when feasible; use a
consistent location.

One gap: the draft did not forbid a *synthesized* percentage. HIG's objection to
vague terms is an objection to text that doesn't inform, and a percentage the app
is estimating is the numeric version of the same failure.

**Correction:** DES-032 now states that a determinate indicator exposes its real
value and total, and that no percentage is displayed unless both are known.

### F-5 — Touch-target rule was quoting the wrong platform (verified, no change)

The 44×44 pt minimum widely cited in HIG summaries — <cite index="15-7">keep tap targets at 44 × 44 points or larger so they're easy to hit</cite> — is
touch guidance. Otos is pointer-driven macOS. `DES-051`'s 28×28 pt minimum click
target with 22–30 pt controls is the correct macOS reading and the same metric the
system's own bars use. No change.

### F-6 — Colour-alone and Reduce Motion rules confirmed (verified, no change)

`DES-029` and `DES-075` match the standard criteria: <cite index="12-7">avoid relying solely on color to convey information — combine color with shapes, labels, or patterns</cite>, and motion that <cite index="11-2">respects the Reduce Motion accessibility setting</cite>. Both already hold, and DES-029's
grayscale-screenshot check is a workable test.

### F-7 — Semantic-colour rule is stronger than "use system colours" (verified)

`DES-020`'s ban on colour literals in views is what makes light/dark parity
structural rather than a review chore — <cite index="12-9">consider using the system colors which automatically adapt to light and dark modes while maintaining proper contrast ratios</cite>.
The DES-022 chrome deviation is the one place Otos defines its own values; it is
defined once, in one place, in both appearances, and every measured pair above is
recorded here.

### F-8 — Alerts and sheets rules match HIG (verified)

`DES-027`, `DES-027A`, `DES-041` follow HIG's alert and sheet guidance as recorded
in the benchmark doc §3: alerts for uncommon destructive actions that can't be
undone; verbs as button titles; destructive styling only for an action the person
didn't deliberately choose; sheets for a scoped task, always modal on macOS, with a
non-Done exit; a panel for supplementary information.

The one open risk is recorded in `import-bar.md`: card erase runs from a stored
preference, so the HIG alert case is deliberately not used. The mitigation is
DES-027A — the consequence is stated on the surface that triggers it.

## Re-test procedure

Run before shipping any user-facing surface:

1. Accessibility Inspector on the built surface, light and dark, on the four text
   levels. Record ratios; anything under 4.5:1 at L1–L3 or 3:1 at L4 is a bug.
2. Grayscale screenshot: every state still distinguishable (DES-029).
3. Reduce Motion on: nothing translates or scales (DES-075).
4. Increase Contrast on: hairlines revert to system separator strength (DES-084).
5. Full keyboard pass with the mouse unplugged (DES-080).
6. VoiceOver: rotor through the surface; the primary line announces once per state
   change, not per tick (DES-083).
