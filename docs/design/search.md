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
  replaced is never shown. A query is in one of three states, and the window shows which:
  - **Being read** (about 40 ms, 0.35 s translated, or as long as Translation or Maps take):
    the grid keeps what it shows, and the window's subtitle reads `Searching…`
    (`Filtered · Searching…` under a filter). It lasts until the reading ends; no timer
    replaces it with anything else.
  - **Read:** the matches, or `No Results for “…”` (below). The subtitle says nothing of
    search.
  - **Could not be read** (a reading that failed; Otos reads it again on its own, 2 s
    doubling to a minute): the grid holds the empty state `Couldn’t Search for “…”`
    (`exclamationmark.magnifyingglass`) over `Otos tries again on its own. The results appear
    here when it succeeds.` It is never shown the scope unsearched, which under the field's
    text would read as the answer. Like an empty result, it shows no tiles, so no painted
    thumbnail is drawn as a placeholder; the matches replace it when a reading succeeds.
- The search stays when the sidebar scope changes: it narrows the new scope. It is not
  restored on relaunch.
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

## What a query can say

- **The picture:** what is in it, in any language ("koira", "kids on a swing").
- **Words in the photo:** a sign's or a screenshot's text, typed as it reads; such photos
  come first.
- **When:** "in September", "July 2024", "2025", "last week", alone or with a picture
  ("beach in September"). A query of dates or places only keeps the scope's order and day
  sections.
- **Where:** a town, a city or an area ("dog in San Francisco", "Lake Tahoe"), by the photos'
  locations.
- **Who:** a person named in People ("Abby at the beach").

Nothing on screen marks which reading a query got; the results are the answer (DES-012: no
L3 is needed for a surface to say what it does).

## Settings

Settings ▸ General gains one row, `Search Languages`, a pop-up of checkable languages
(Translation's, named in the user's language) whose title lists the chosen ones
(`English, Finnish`). It starts as the system's preferred languages; one stays chosen. Its
tooltip: `Searches in these languages are understood best`.

## Levels

| String | Level |
| --- | --- |
| The scope's title | L1 (unchanged) |
| `No Results for “dog”` / `Couldn’t Search for “dog”` | empty-state title (`.title2`, DES-003), the empty grid's primary fact |
| `Check the spelling…` / `Otos is still reading N items…` / `Otos tries again on its own…` | empty-state message, L3 |
| `Searching…` (beside `Filtered`, a middot apart, DES-034) | window subtitle, L3 under the scope's title |

The subtitle sits in the toolbar's title block, as `Filtered` does: the toolbar keeps its
height in every state, so the grid never reflows (DES-018, DES-053). The three states differ in words and glyph,
never in color alone (DES-029).
| `Relevance` | L2 menu item |

## Accessibility

The field is the system's, so VoiceOver names it `Search` and Tab reaches it in toolbar
order (DES-080). Results are the grid's ordinary tiles (DES-082).
