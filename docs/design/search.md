# Search — Spec

Keyword search: a toolbar field that narrows whatever scope is shown to the photos and videos
its text describes, in any language. Cites `docs/design/design-system.md` by ID; rules are not
restated. Decision record: `docs/adr/0048-keyword-search.md`.

Owners: the field and Edit ▸ Find in `Otos/ContentView.swift` and `Otos/OtosApp.swift`; the
search state in `CatalogWindowViewModel.setSearchText`; results from `PhotoSearchIndex`
through `CatalogProjection`.

## Reference

Lightroom (desktop and web) puts a search field above the grid that understands descriptions
("a man wearing a yellow jacket") and offers its results by Relevancy or Capture Date
(Adobe Help, *Sort and segment photos in the grid view*; *Explore results with semantic
search*). Photos puts its search field at the trailing end of the toolbar, focused by
Edit ▸ Find (⌘F), and says `No Results for “…”` when nothing matches. Otos takes Photos'
field, menu item and empty state, and Lightroom's two orders. It adds nothing of its own.

## The field

- The system search field (`.searchable`, toolbar placement), at the trailing end of the
  toolbar, with the prompt `Search`. Edit ▸ Find (⌘F) focuses it.
- Typing searches as the text changes; Return is not needed, and an emptied field, or the
  field's clear button, ends the search. The newest text wins: a result for text since
  replaced is never shown.
- The search stays when the sidebar scope changes: it narrows the new scope, as the filter
  does. It is not restored on relaunch.
- Bare-key commands (DES-093) never fire while the field is being edited.

## Results

- The scope's grid, loupe and Compare show only the matches, with the current filter still
  applied. The surface's L1 is unchanged: the scope's title (DES-010).
- **Order:** the Sort menu gains `Relevance` above its other orders while a search is shown,
  and a new search starts there. Relevance is best match first, as one ungrouped section: day
  headers (DES-069) belong to Date order, and relevance does not keep dates together.
  Choosing any other order shows the matches in it, with Date's day sections. Ending the
  search leaves the scope's own sort as it was.
- **Empty:** the empty state (`CatalogMediaEmptyStateView`) reads `No Results for “dog”`
  (`magnifyingglass`), and under it either `Check the spelling or try a new search.` or,
  while some items have not been read for search yet, `Otos is still reading 1,204 items for
  search. They appear here if they match.` (the honest-numbers principle: a count, never a percentage). A
  scope that holds nothing keeps its own empty state.

## Levels

| String | Level |
| --- | --- |
| The scope's title | L1 (unchanged) |
| `No Results for “dog”` | empty-state title (`.title2`, DES-003) |
| `Check the spelling…` / `Otos is still reading N items…` | empty-state message, L3 |
| `Relevance` | L2 menu item |

## Accessibility

The field is the system's, so VoiceOver names it `Search` and Tab reaches it in toolbar
order (DES-080). Results are the grid's ordinary tiles (DES-082).
