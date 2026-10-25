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
6.2:1 against the bar chrome). The tertiary level is reserved for non-text elements
— hairlines, disabled glyphs — where the 3:1 non-text rule applies and the drafted
values pass. The former ambient value was retired with the unused level.

Re-measured 2026-08-13 against `DesignPalette`'s shipped values (`DesignPaletteTests`
computes WCAG contrast from the actual resolved `Color`s, alpha-composited over the
bar chrome) — the L3-dark figures above were revised from the original
estimate (6.0:1, 4.4:1) to match.

### F-2 — The retired ambient level carried information it could not legibly carry

`DES-013` allowed `.footnote` at tertiary for "metadata that is looked up". At
1.9:1 that text is not reliably readable by a low-vision user, which makes the
level dishonest rather than quiet.

**Correction (2026-08-13):** The former ambient level kept its size but took the
value from F-1, and
DES-013 stated that anything a user may need to *read* — as opposed to notice the
presence of — is L3 or above.

**Retired:** the ambient palette entry and DES-013 are deleted.
No surface ever grew the ambient metadata (tile filename, loupe metadata) DES-013
was drafted for, so the corrected value had zero real callers — an unused level
carrying a legibility fix for content that doesn't exist. This finding stays for
the record; the fix it describes no longer applies to a current rule.

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

## Edit panel audit (2026-10-25)

The edit panel (DES-092, `edit-panel.md`) as built through plan 0108 increment 7, read
against the HIG pages that govern it: Split views, Toolbars, Panels, Sliders, Pop-up
buttons, Disclosure controls, Keyboards, The menu bar, Undo and redo, and Color
(developer.apple.com/design/human-interface-guidelines, read 2026-10-25). Lightroom
desktop's command list (helpx.adobe.com, Lightroom keyboard shortcuts) is the product
reference where the HIG leaves room.

### F-9 — What already conforms (verified, no change)

- **A trailing, collapsible split-view pane**, shown and hidden by a toolbar button, a
  View menu command and a shortcut. Split views (macOS): "Provide multiple ways to
  reveal hidden panes", using "a toolbar button or a menu command — including a
  keyboard shortcut". Its width is bounded at 240–360 pt: "Set reasonable defaults for
  minimum and maximum pane sizes."
- **The toolbar button sits on the trailing edge**, before the More menu. Toolbars:
  the trailing edge holds "buttons that open nearby inspectors", and every toolbar item
  is also a menu-bar command.
- **The show/hide title follows state**, as The menu bar requires.
- **It acts on the selection and follows it**, as Panels describes an inspector.
- **Sliders** run minimum-leading, including a RAW's kelvin, and give live feedback
  while dragging (Sliders, macOS).
- **Done is the one prominent, accent-backed action and answers Return** (Toolbars;
  Color: the accent "to the background in prominent buttons — such as the Done
  button").
- **Undo names the act** (`Undo Exposure`, `Undo Crop`), each section's Reset reverts
  related adjustments in one step, and both live in the Edit menu under ⌘Z / ⇧⌘Z
  (Undo and redo).
- **Aspect is a pop-up** of mutually exclusive choices, with a sensible default
  (Original) and a Custom choice (Pop-up buttons).
- **Crop, Rotate and Flip are commands in an app-specific Photo menu** (The menu bar:
  list app-specific commands in the menu bar, where Full Keyboard Access reaches them).

### F-10 — Slider fills deviate from the default accent fill, unmarked (applied)

Sliders: the track up to the thumb "fills with color" by default, and a slider's
appearance may be customized "if it adds value". Color: reserve color for "elements
that truly benefit from emphasis". Increment 7 gave the panel's slider fills the neutral
secondary color (DES-092) without marking the change a deviation, as `design-system.md`
requires for any departure from a macOS default.

**Correction:** DES-092 marks it **[deviation]** with its reason. There are nine
sliders on one surface, most of them neutral at their midpoint, where an accent fill
from the leading edge reads as an amount and turns the panel into a column of
highlights competing with the photograph (DES-024).

### F-11 — The menu command names the panel "panel" (applied)

Panels: "In menus, use the panel's title without including the term panel: for example,
'Show Fonts,' 'Show Colors,' and 'Show Inspector.'" Otos says View ▸ Show Edit Panel /
Hide Edit Panel. Lightroom desktop names the same command **Edit** (E).

**Applied:** View ▸ Show Edit / Hide Edit, with the toolbar tooltip to match (DES-092).

### F-12 — Single-letter shortcuts are an unrecorded deviation (applied)

Keyboards: "A keyboard shortcut is a combination of a primary key and one or more
modifier keys"; single keys are described as games' key bindings. The standard
shortcut for an inspector is Option-Command-I ("Display an inspector window"). Otos
binds bare letters, following Lightroom: E (edit panel), C (crop), I (info), Z (actual
size), P / U / X (curation). They work only because no text field holds focus there.
They conflict with no standard shortcut, but nothing records the choice.

**Applied as DES-093**, marked **[deviation]**: Lightroom's
single-letter commands, each a menu item, active only while no text field has focus.
Keep E rather than adopt ⌥⌘I; a menu item carries one key equivalent, and E is what
the product's users already know.

### F-13 — A free crop has no Shift-to-constrain, and the crop cannot be nudged (applied)

Keyboards: "pressing Shift while drag-resizing constrains resizing to the item's aspect
ratio", and "holding an arrow key moves the selected item by the smallest app-defined
unit". With the aspect set to Custom, a handle drag ignores Shift. The crop canvas takes
no keyboard focus, so arrow keys do nothing, and the only keyboard path to a crop is an
aspect choice, which centers it (DES-080).

**Applied:** Shift during a handle drag keeps the crop's shape at the drag's start. While
the tool is on, an AppKit key view holds first responder (SwiftUI focus could not take it
from the filmstrip) and returns it when the tool ends. The arrow keys move the crop one
pixel of the frame, Shift-arrow ten, and a held key saves as one step on release.

### F-14 — The Aspect pop-up has no introductory label (applied)

Pop-up buttons: "Give people a way to predict a pop-up button's options without opening
it. For example, you can use an introductory label". The Aspect menu shows only its
current value (`Original`), and its accessibility label is not visible.

**Applied:** an `Aspect` label at L2, on a row of its own.

### F-15 — Wide-range sliders have no exact entry (applied)

Sliders: "Consider supplementing a slider with a corresponding text field and stepper.
Especially when a slider represents a wide range of values, people may appreciate
seeing the exact slider value and having the ability to enter a specific value."
Temperature spans 2000–50000 K, and Straighten ±45° in 0.1° steps. Each value is static
text. Lightroom lets the value be typed. Panels' advice to prefer sliders over typing
still holds: the slider stays the main control.

**Applied:** the value on each control's line is an editable numeric field, still
`.monospacedDigit()` at L2. Return or leaving the field saves the value as one step, an
out-of-range entry clamps, and Escape restores it.

### F-16 — Sections cannot be collapsed (applied)

Disclosure controls: "Use a disclosure control to hide details until they're relevant."
Apple's own inspectors and Lightroom fold their sections. With Crop, Light and Color the
panel just fits a 896 pt window (measured in the dev build); Effects, Detail and Optics
(increments 8–10) will make it scroll.

**Applied:** each section heading is a disclosure triangle ("points inward from the
leading edge when its content is hidden"), all sections open by default, and each
section's open or closed state remembered across launches. DES-053 concerns a state
changing under the user, not a section the user folds, so it is not affected.

### F-19 — Two keyboard defects found while applying F-11–F-16 (applied)

Found in the dev build, not by reading:
- **E and C never fired from the grid or filmstrip.** The collection view handled P/U/X,
  Z and I itself and passed every other letter to `NSCollectionView`, which consumed it
  as type-select, so a bare menu key equivalent never reached the menu. Now an unhandled
  bare letter is offered to the menu bar first, and the collection view's own Z and I
  forwarders are gone, leaving one path per command.
- **⌘A, ⌘C, ⌘X and ⌘V could not edit a value field's text.** The app replaces the
  pasteboard commands: Select All selected photos, Copy copied photos, and Cut and
  Paste did not exist. Now, while a value field is being edited, all four act on its
  text through the responder chain (DES-093).

Also measured: a bare letter typed into a focused value field goes into the field. It does
not fire its menu command.

### F-17 — The RAW temperature slider is nonlinear with no scale marks (proposed, low)

Sliders (macOS): "When the values of the slider are nonlinear… periodic labels provide
context", and a tooltip can show the value under the thumb. The kelvin slider is even in
mireds, so equal distances are unequal kelvin, and nothing on the track says so.

**Proposed:** none until the editable value of F-15 exists, which shows the exact kelvin;
reconsider tick marks after that.

### F-18 — An undone edit to a photo off screen is not shown (proposed, low)

Undo and redo: "Show the results of an undo or redo… if the action people want to undo
affects content… that's no longer visible." Undoing an edit after moving to another
photo changes a thumbnail somewhere in the grid without revealing it.

**Proposed:** none yet; it applies equally to curation (APP-039), so it belongs to one
decision for the whole undo stack, not to the edit panel alone.

## Re-test procedure

Run before shipping any user-facing surface:

1. Accessibility Inspector on the built surface, light and dark, on the four text
   levels. Record ratios; anything under 4.5:1 at L1–L3 is a bug.
2. Grayscale screenshot: every state still distinguishable (DES-029).
3. Reduce Motion on: nothing translates or scales (DES-075).
4. Increase Contrast on: hairlines revert to system separator strength (DES-084).
5. Full keyboard pass with the mouse unplugged (DES-080).
6. VoiceOver: rotor through the surface; the primary line announces once per state
   change, not per tick (DES-083).
