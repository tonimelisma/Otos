# Liked Curation Interaction And Copy Research

Date: 2026-08-12

## Question

How should Otos expose one three-state curation choice — **Liked**, **Not Rated**,
or **Disliked** — across Grid, Loupe, Compare, and their shared filmstrip, while
remaining fast for pointer and keyboard culling, truthful about what the state
means, and usable with VoiceOver and Full Keyboard Access?

This research records the evidence used by Plan 0091. It does not claim that the
feature is implemented.

## Approved Product Direction

- Each cataloged image or video has exactly one mutually exclusive choice:
  `liked`, `notRated`, or `disliked`.
- User-visible state names are **Liked**, **Not Rated**, and **Disliked**.
- Liked uses a heart, Not Rated a minus, and Disliked an X in the hover group.
- `P`, `U`, and `X` choose Liked, Not Rated, and Disliked respectively.
- Media carries no persistent curation badge or dimming. Every browsing
  presentation reveals all three choice controls only while that item is hovered,
  following the Photos app's low-chrome approach.
- A persistent setting named from the behavior controls whether a completed
  choice advances to the next item.
- **Photo > Move to Trash** uses Command-Backspace to move the targeted original
  and its cataloged physical members to the system Trash.

## Competitor Findings

### Lightroom Classic

Lightroom Classic uses one three-state flag: Pick, Unflagged, or Rejected. `P`,
`U`, and `X` set those states. Grid cells can expose flags in the upper-left;
rejected thumbnails are dimmed. Grid and Loupe can expose a toolbar flagging
control, while Compare and Survey keep per-photo controls beneath each photo.
Filtering addresses Flagged, Unflagged, and Rejected independently.

Compare is not symmetric: the left photo is the active Select and the right is
the Candidate. `P/U/X` affect the active Select. Swap reverses the two roles,
and Make Select promotes the Candidate. Otos deliberately retains peer left and
right positions instead, so it needs an explicit active-pane target for keyboard
choice without importing Select/Candidate roles.

Sources:

- [Flag, label, and rate photos](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/flag-label-rate-photos.html)
- [Browse and compare photos](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html)
- [Find photos in the catalog](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/finding-photos-catalog.html)
- [Library view options](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/setting-library-view-options.html)

### Lightroom (cloud/Desktop)

Lightroom cloud also stores Picked, Unflagged, and Rejected, but presents them
through Photo Grid, information-rich Square Grid, Detail, full screen, context
menus, and a Filter panel rather than Classic's Library module. Square Grid
shows flag and rating state and reveals direct controls on hover. Desktop uses
`Z/U/X`, not Classic's `P/U/X`. Cloud Compare is current edit versus original
for one asset, not two-photo culling.

Sources:

- [Organize photos in Lightroom](https://helpx.adobe.com/lightroom/desktop/organize-photos/organize-photos.html)
- [Lightroom Desktop keyboard shortcuts](https://helpx.adobe.com/lightroom/desktop/using/keyboard-shortcuts.html)
- [Filter photos and videos](https://helpx.adobe.com/lightroom/mobile/search-and-filter-photos/filter-photos-and-videos.html)
- [Compare edited and original photos](https://helpx.adobe.com/lightroom/web/get-set-up/learn-the-basics/compare-photos.html)

### DxO PhotoLab

DxO uses Picked, Untagged, and Rejected, with green and red dots plus grayscale
reinforcement for rejected thumbnails. It supports both `7/8/9` and Lightroom's
`P/U/X`, offers the three states in its Image Browser filter, and recommends a
multi-pass workflow: cull, filter to picks, then revisit rejected and untagged
items. Otos should reuse the efficient three-state workflow, not DxO's reliance
on red/green because Otos reserves those colors and forbids color-only meaning.

Source: [Manage images and metadata in PhotoLab](https://userguides.dxo.com/photolab/en/managing-images/)

### Capture One and Photo Mechanic

Capture One primarily uses star ratings and configurable color tags rather than
a universal pick/reject state. Its Browser and Viewer both expose the current
rating/tag, and an optional Select Next When preference advances after a rating
or tag. Photo Mechanic similarly supports tags, ratings, and configurable color
classes, plus automatic advance after a mark changes. These products establish
advance-after-choice as a durable personal workflow preference, not a default
side effect that should surprise every user.

Sources:

- [Capture One rating and tagging](https://support.captureone.com/hc/en-us/articles/360002743718-Rating-and-tagging)
- [Capture One Viewer overview](https://support.captureone.com/hc/en-us/articles/360002468897-The-Viewer-overview)
- [Photo Mechanic quick-start preferences](https://home.camerabits.com/setting-up-photo-mechanic-quickstart-guide-to-preferences/)
- [Photo Mechanic color classes](https://docs.camerabits.com/support/solutions/articles/48001142942)

## Apple HIG Review

### Clear, consistent copy

Apple recommends concise, direct wording; stable language patterns; and verbs
for actions. State and action copy therefore have different grammatical jobs:

| Purpose | Liked | Not Rated | Disliked |
| --- | --- | --- | --- |
| state/filter value | `Liked` | `Not Rated` | `Disliked` |
| button tooltip | `Like` | `Mark as Not Rated` | `Dislike` |
| menu command | `Like` | `Mark as Not Rated` | `Dislike` |
| VoiceOver value | `liked` | `not rated` | `disliked` |
| VoiceOver action | `Like item` | `Mark item as not rated` | `Dislike item` |

`Not Rated` is approved product copy, but it has a known semantic cost: people
may expect a star-rating system when they read "rated." Plan 0091 must not add
stars or a second rating concept. If a future increment proposes stars, it must
first resolve the vocabulary collision rather than silently making two meanings
of rating coexist.

The setting label should say what changes, not use the abstract phrase "on
choice": **Advance after choosing Liked, Not Rated, or Disliked**. Supporting
copy is unnecessary because the label is complete. The checkbox defaults off.

Sources:

- [Writing](https://developer.apple.com/design/human-interface-guidelines/writing)
- [Labels](https://developer.apple.com/design/human-interface-guidelines/labels)
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles)

### Hover-only content chrome still needs equivalent access

The approved Photos-inspired direction keeps pointer controls absent until hover
so media surfaces stay quiet. Otos adopts that presentation deliberately: there is no
resting heart, X, dimming, or always-visible toolbar choice group. This is a
low-chrome presentation decision, not a pointer-only capability. The same
operations remain available through menu commands, `P/U/X`, and VoiceOver custom
actions. Invisible buttons do not enter Full Keyboard Access order. Grid and
filmstrip retain collection keyboard navigation; Loupe and Compare retain a
perceivable active target for `P/U/X` without revealing the hover group.

Sources:

- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)
- [VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)

### Icons and state communication

Apple recommends simple, familiar symbols and alternative labels, and prohibits
depending on color alone. Otos's system is:

- Liked: `heart.fill` in the hovered control when selected; otherwise `heart`.
- Not Rated: `minus` in the hovered middle control.
- Disliked: `xmark` in the hovered control.

During hover, the current choice is indicated with both the selected control
shape and `accessibilitySelected`, not tint alone. Symbols use semantic
foreground/material colors. Otos does not use green for Liked or red for
Disliked: the design system reserves green for verified completion and red for
destruction. At rest, all three states have identical visual treatment.

Sources:

- [Icons](https://developer.apple.com/design/human-interface-guidelines/icons)
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)

### Settings placement

Apple recommends keeping durable, infrequently changed experience preferences
in the app's Settings window. The advance preference meets that test. Otos needs
a General pane rather than placing browsing behavior under Libraries, Removable
Media, or Import. Use a checkbox in the grouped form and preserve the standard
Command-Comma Settings entry point.

Source: [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)

### Recoverable deletion copy and feedback

Apple distinguishes a routine, recoverable destructive action from unexpected or
irreversible loss. Finder does not interrupt every Move to Trash action with an
alert. Otos therefore names the command **Move to Trash**, uses the established
Command-Backspace shortcut, and does not show a success or confirmation alert.
It never falls back to permanent deletion. A failure is actionable and gets one
alert: **This Item Couldn't Be Moved to Trash** for one item, or **Some Items
Couldn't Be Moved to Trash** for a batch, with **Show in Finder** and **Dismiss**.

Photos confirms a different but useful precedent: its Delete command confirms
before moving library items to Recently Deleted. Otos does not copy that library
semantics because its source of truth is the user's filesystem and the system
Trash is recoverable. The difference must be tested as an intentional filesystem
interaction, not described as Photos parity.

Sources:

- [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)
- [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [Delete photos in Photos on Mac](https://support.apple.com/guide/photos/delete-photos-from-icloud-on-mac-phtda347cde8/mac)

## Reviewed Interaction Design

### Resting and hover presentation

| Surface | At rest | On pointer hover |
| --- | --- | --- |
| Grid tile | no curation chrome | upper-left three-choice control: heart, minus, X |
| Loupe preview | no curation chrome | three-choice control inset from the pane's top-left |
| Compare pane | no curation chrome; active pane keeps its standard keyboard-target indication | controls for that pane only; clicking the pane, not hovering, makes it active |
| Filmstrip tile | no curation chrome | compact heart, minus, X control |

Hover never changes choice or active Compare pane by itself. Controls stay
visible while the pointer moves between their buttons, and disappear after the
tracking region exits. A control click consumes the event so it cannot also
select, double-click, play a video, or replace a Compare pane.

The hover group is the only direct control drawn over media. There is no overlay
trash button; deletion remains a scoped menu/shortcut command. State is still
discoverable in the Curation filter and accessibility value even though resting
media has no visual badge.

### Advance semantics

The preference defaults off. When on, an accepted user choice advances even if
the stored value was already the chosen value; this makes `U` a useful "leave
Not Rated and continue" command. Advancement occurs after Store has accepted
the operation. A failed write does not move the user.

- Grid keyboard/menu batch: update the selection atomically; advance to the first
  item after the last affected item in the pre-choice display order and make it
  the sole selection.
- Grid/filmstrip inline control: update that exact item; advance from that item.
- Loupe: update the focused item; focus the next item.
- Compare: update the active pane's item; replace that positional pane with the
  next display-order item not already in the other pane. The other pane remains.
- End of scope: retain the current item/pair; do not wrap.
- Active filter removes the chosen state: compute the successor from the
  pre-choice order, then accept it only if it survives the new descriptor. Do
  not apply a second automatic step when projection reconciliation arrives.

## Conclusion

The reviewed design satisfies the approved warm, minimal heart/X language while
retaining professional three-state semantics. Its critical safeguards are quiet
resting media, equivalent non-pointer access paths, an explicit Compare target,
lossless mutation delivery, successful-write advancement, recoverable system-
Trash deletion, and precise copy. Plan 0091 owns implementation and falsification.
