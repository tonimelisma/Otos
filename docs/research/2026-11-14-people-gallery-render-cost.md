# The People gallery's main-thread cost (2026-11-14)

## Question

On the reference catalog (738 people, 102,753 faces, faces still being read), the installed app
(72dfc9b8) stalled the main thread for about 8 s when People opened, and for about 0.3 s after
every People update, one every few seconds while faces were read. Every stall's stack ran
through `PersonCell.body` into `CatalogWindowViewModel.galleryPersonMenu(_:)` and
`CatalogPeopleState.visiblePeople`. What does each cell do while it renders, and what does an
update make the gallery do again?

## Method

- Code reading of `PeopleView`, `CatalogWindowViewModelPeople` and `PeopleModels` at 72dfc9b8.
- A temporary hosted test (not committed): 500 cells in a `LazyVGrid` in an `NSHostingView`
  in an off-screen window, each with a `.contextMenu` and an `.accessibilityActions` whose
  content is a child view counting its own body evaluations.
- `OtosTests/PeopleGalleryRenderTests.swift`: a generated People state of 738 people over
  about 100,000 faces, and of 5,000 people over 100,000, applied to a window view model
  (not started) and rendered by `PeopleView` as `ContentView` hosts it, in a 1200 × 800
  off-screen window. Measured: the main thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`) to
  apply the state and render the gallery; then five updates each giving one person one more
  photo; then a click, a ⌘-click and a ⇧-click. Each step counts the menus the cells asked
  the view model for. The machine ran other agents' builds and tests throughout, so the
  times are indications; the menu counts are exact.

## Findings

1. **Every rendered cell built its context menu twice**, once in `.contextMenu` and once in
   `.accessibilityActions`, both closures SwiftUI evaluates with the cell's body
   (`PeopleView.swift` at 72dfc9b8, lines 304–318). Each build filtered every person
   (`CatalogPeopleState.visiblePeople` was a computed filter) to find the selection's other
   people: O(people) per cell, O(people × cells) per render.
2. **Every update re-rendered every live cell.** A cell's inputs included the gallery's
   intent closures, which compare unequal on every window update, and its menu read the
   view model's whole `state` inside the body, so any window state change, People or not,
   invalidated every cell.
3. **Lookups walked the people.** `CatalogPeopleState.person(_:)` was a linear search; the
   view model rebuilt a dictionary of every person on the main actor with each People
   state (`PeopleIndex`); the Person sheet, rebuilt by the window on every update while it
   is open, walked every face of every photo (`photoFaces.values.flatMap`) to find eight;
   and the toolbar menu of a person's photos judged a merge into every named person inside
   the toolbar's body, each judgement walking one person's anchor photos.
4. **SwiftUI does not evaluate a context menu's or an accessibility-actions content view
   while the cell renders.** In the hosted probe, the 25 cells rendered evaluated both
   closures 25 times and neither child view's body once. A child view whose body asks for
   the menu defers the menu to its use.

| 72dfc9b8 | open (CPU ms) | menus at open | per update (CPU ms) | menus per update |
| --- | --- | --- | --- | --- |
| 738 people | 437 | 80 | 97–156 | 80–96 |
| 5,000 people | 621 | 80 | 529–563 | 80 |

After this change, same test, same machine load (load average 50–100):

| this change | open (CPU ms) | per update (CPU ms), of it applying the state | per click | an unrelated window state | menus built |
| --- | --- | --- | --- | --- | --- |
| 738 people | 472 | 34–99, 0–5 | 19–21 | 0 | 0 |
| 5,000 people | 180 | 28–90, 3–4 | 22–101 | 1 | 0 |

The open figure is mostly the test process's first SwiftUI window (the 738 case runs first,
and the larger gallery opens in less); it no longer grows with the people. An update's cost
no longer grows with them either: 5,000 people cost what 738 do, almost all of it SwiftUI
laying out the grid again after a person moves up, the state's own apply 0–5 ms. A window
state that changes nothing in People renders nothing in the gallery.

## Conclusion

The People state carries what the gallery and the menus look up, derived where it is built
off the main actor (visible and hidden people, the sheet's names, each person's index, each
person's newest faces); the cell renders from its own person and selection and is equal to
the cell it replaces while they are, and the gallery equal to the one it replaces while its
People state and selection are; its menu and VoiceOver actions are child views that ask for
the menu as they open; and the toolbar menu of a person's photos is built once per People
state or scope (ADR 0047, APP-072). Not measured: the installed app on the reference catalog
(never launched by an agent), and VoiceOver reading a cell's actions.
