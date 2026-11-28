# Activity

GOVERNS: `OtosKit/Views/ActivityView.swift`, `OtosKit/Views/ActivityPresentation.swift`, `OtosKit/Services/ActivityBoard.swift`

The surface that answers what a user asks of Otos's background work — is everything here
yet, is something wrong that I can fix, is Otos busy — and nothing else (ADR 0058, DES-124;
the HIG review is `docs/research/2026-11-27-activity-and-the-hig.md`). Most of Otos's work
runs unasked, over hours on a large cloud library: making thumbnails, reading photo info,
scanning for faces, looking up place names, indexing for search, writing descriptions,
finding duplicates, syncing an Immich account. None of it belongs to a sidebar selection, so no bar at the bottom of the
content pane can own it (DES-040). It has one place: a line at the foot of the sidebar, and
the popover it opens. It never says when work ran.

## L1 primary fact

The popover: `Working on 3 things`, else `Waiting on 2 things`, else `Up to date`.

The sidebar's `Duplicates` count is the photos that have duplicates; hovering it, or
VoiceOver, says so (`95 photos have duplicates`).

## The line

At the sidebar's foot, under every section, behind a hairline, on the sidebar's own color,
at one fixed height in every state (DES-053): a 16 pt glyph level with the L2 line, then L2
over L3. A line with no L3 is centred in that height, so `Up to date` sits level with its
checkmark.

| State | Glyph | L2 (`body`) | L3 (`subheadline`) |
| --- | --- | --- | --- |
| Before the window's work is watched (the first grid has not painted) | none | blank | blank |
| Something needs the user, whatever else works | `exclamationmark.triangle`, orange | what it stops (`Writing descriptions`) | `and 2 more`; for one row alone, the first sentence of what to do (`Turn on Apple Intelligence in System Settings to describe photos`) |
| Something working | small spinner (DES-072) | the one that has worked longest (`Scanning for faces`) | `and 2 more` (the popover's other rows), or none |
| Nothing working, something paused or waiting | `pause.circle`, secondary | what waits (`Writing descriptions`) | `and 1 more`; for one row alone, the first sentence of what stops it (`Apple Intelligence isn’t responding`) |
| Nothing working or waiting | `checkmark`, secondary | `Up to date` | none |

The line names the work that started first, so a short job that starts beside a long one
changes only the count. Clicking it, or Space / Return on it with Full Keyboard Access, opens
the popover; it is disabled while nothing is known. VoiceOver reads `Activity, Scanning for faces,
and 2 more`.

## The popover

Inspection (DES-041), 320 pt wide, anchored to the line's trailing edge: the L1 header, then
one row for each piece of work that works, is paused, waits or needs the user, in a fixed
order, each Immich account after, then `Everything else is up to date` in L3 when anything
watched is not listed. With nothing working or waiting, the header alone. A row is the work's
glyph, what it does (L2), how many items it has left (L3), the downloads it waits on (L3),
each problem the user would notice as its own L3 line, a determinate bar under them, and one
indicator at the trailing edge, level with the name:

| Status | L3 | Bar | Trailing |
| --- | --- | --- | --- |
| Working | what is left, the downloads it waits on, then a source that is not available for some of its items | yes, while counted | none (the bar is its indicator); a small spinner only with nothing counted |
| Paused | what is left, the machine condition (`Paused while memory is low.`, `Paused while the Mac cools down.`, `Paused in Low Power Mode.`), then what stops it | none | none |
| Waiting | what is left, then what stops it, or `Otos will try these again later.` when its items wait out their own failures | none | none |
| Needs you | what is left, then what to do; an account's row carries `Open Settings…` | none | `exclamationmark.triangle`, orange |

A row draws one indicator, never two and never switching between a spinner and a bar (HIG
Progress indicators). The row's one act — `Open Settings…`, where a signed-out account signs
in again — is its own control under its words; everything else in the popover is read-only.

A row stays in its state through its work's retries: a row that waits keeps waiting, with what
stopped it, until an item finishes (ADR 0058). A retry that fails changes nothing on screen.

## Problems

A problem is said only when the user would notice it (`OwnerTrouble.Standing`); people expect
work to succeed and need to hear when it does not (HIG Feedback), and an error says what can
fix it (HIG Writing).

| Standing | Said | Cause | L3 |
| --- | --- | --- | --- |
| Needs you | first, on the line too | Disk full | `The disk is almost full. Free up space, and Otos will go on.` |
| | | Apple Intelligence off | `Turn on Apple Intelligence in System Settings to describe photos.` |
| | | Account signed out | `You’re signed out of this account. Sign in again in Settings.` with `Open Settings…` |
| Unavailable | on the row it stops | A cloud provider failing | `“Camera Roll” isn’t answering. Otos will try again.` — the libraries named as the sidebar names them; `The cloud provider isn’t answering. Otos will try again.` when a name is not known |
| | | Face model missing | `The face finder couldn’t start. Otos will try again.` |
| | | Mac not eligible | `This Mac can’t run Apple Intelligence.` |
| | | Model not ready | `Apple Intelligence isn’t ready yet. Otos will try again.` |
| | | Model service failing | `Apple Intelligence isn’t responding. Otos will try again.` |
| | | Model busy | `Apple Intelligence is busy. Otos will try again.` |
| | | Place names failed | `Place names couldn’t be looked up. Otos will try again.` |
| | | Search failed | `Search couldn’t be updated. Otos will try again.` |
| | on the account's row | Account offline | `The server isn’t answering. Otos will try again.` |
| | on the account's row | Server has not read some assets | `The server hasn’t processed 943 photos and videos yet. They appear once it has.` — the assets with no metadata and no images yet, which Otos does not show, as the server's own timeline does not (v84) |
| Retried | never | One download, one ranged read a server did not answer, one RAW's camera support, one item's faces, one description | — the item stays counted as left; a row whose items all wait says `Otos will try these again later.` |
| User work only | never, and not counted | An item whose source sends its original only for the user's work (ADR 0046 §4) | — |

No row shows a time: the surface answers "is it done, working, or stuck", not "when".

## Progress

Every row says how much is left, and each working row has a progress bar. A user looking at background work asks what
it is doing, how much is left, why it runs when that is not obvious, and what stops it; the
row answers each, in that order.

| Work | L3 | Counted from |
| --- | --- | --- |
| Making thumbnails | `1,056 photos and videos left`, then `Downloading 214 of 1,020 · 3.2 GB of 9.8 GB` while background downloads let them be read | the rows enrichment's claims owe a thumbnail made or remade (`EnrichmentPurpose.thumbnail`); never an Immich account's, whose sync brings them; the downloads' current run and their catalog sizes, no bytes when one has no size on record |
| Reading photo info | `1,053 photos and videos left` | the rows owed the details the Info pane shows (`EnrichmentPurpose.info`), less those only the user's work can read |
| Scanning for faces | `12,198 photos and videos to scan` | the stills not yet checked for faces, and the videos enrichment owes their faces (`EnrichmentPurpose.faces`) |
| Looking up place names | `894 locations to look up` | the map's areas (cells of nearby photos) with no name in the user's language: never a count of photos |
| Indexing for search | `22,308 photos and videos left` | the items owed a search embedding |
| Writing descriptions | `38,100 photos left` | the stills owed a description |
| Finding duplicates | `31,310 photos and videos to compare` | the stills owed a render signature, which the groups are built from, and the files owed the digest that tells exact copies apart (`EnrichmentPurpose.copies`) |
| Scanning for faces, grouping | `Grouping faces into people`, a spinner, no bar | the faces found are being assigned to people (`PeopleAssignment`), which no count measures: shown while only that moves the row, with the scan's count after it only while stills are left |
| Finding duplicates, grouping | `Grouping duplicates`, a spinner, no bar | the duplicate groups are being built from the fingerprints (`DuplicatesProjection`), which no count measures: shown while only that moves the row |
| Syncing “Home”, listing | `18,400 photos and videos so far`, no bar | the assets the pass's stream has listed: the stream names no total ahead of its end, and the server's own statistics need not count what it lists |
| Syncing “Home”, images | `2,100 of 6,000 thumbnails` | the rows tried of those owed the server's images when the fetch began, counted over the walk's own index; with no count, `2,100 thumbnails so far` and no bar |

HIG review (Progress indicators):

- **Determinate wherever the amount is known.** Every count is exact (ADR 0058): what is left
  is a COUNT over the predicate the work's own walk reads, and what is done is the items its
  owner wrote, counted as it writes them. So every working row has a bar. No row shows a
  percentage, a remaining time or a rate.
- **The words say what is left; the bar, the stretch.** The L3 count is what is left, the
  number a user reads at a glance. The bar is the stretch's: `done` is what the work's owner
  finished since the work began, `total` is `done` plus what is left now. The bar moves only as
  the owner finishes items; when new photos arrive the total steps up, which is the truth, and
  done stays. An item that stops being owed for another reason — its facts changed again, its
  file gone — lowers the total and is never counted done.
- **Say the step no count measures.** A row whose items are done while their result is still
  being built — faces into people, fingerprints into duplicate groups — says that step and
  spins, instead of `0 … to scan` beside a full bar that never finishes.
- **A bar only while the work moves.** A paused or waiting row keeps its count, with what stops
  it under the count, and draws no bar: a bar says work is progressing, and it is not: whatever the
  problem, the status is right.
- **Keep the indicator steady.** A row's state follows its items, not its owner's every wake:
  retries of items that wait out a failure keep it waiting, so its bar does not flicker in and
  out.
- **Say why when it is not obvious.** Downloads are a means, not an outcome: they are the line
  of the row whose photos they let show, never a row. A file still downloading cannot be
  measured from its provider, so the run moves as each one finishes.
- **The line stays one line.** The sidebar's line keeps its fixed height and names the work;
  the counts and bars are the popover's.

VoiceOver reads each row as one element: its name, its count, its bar's value and what stops
it; a row's act is its own control after it.

## Names

Each row is a verb and the thing Otos makes, in words a user knows (DES-035; HIG Writing:
"Choose words that are easily understood and convey the right thing"; Progress indicators:
"Avoid vague terms like loading"), so it says what Otos does and the user can find what it
gives them in the app. Each piece of enrichment's work is filed under the one row whose
outcome it serves (`EnrichmentPurpose`), never under a row of its own.

| Work | Row and line |
| --- | --- |
| A thumbnail and preview made for each photo or video, or remade when its file changed or a RAW is developed, and the downloads that let it be read | `Making thumbnails` |
| The details the Info pane shows — dates, camera, lens, place — read from each file, or from an account's server, and read again after Otos learned to read more | `Reading photo info` |
| Faces detected in stills' previews and videos' frames, then grouped into people | `Scanning for faces` |
| Towns and countries for the map's areas | `Looking up place names` |
| What search compares a query with, made for each item | `Indexing for search` |
| A description of each still, written by Apple Intelligence | `Writing descriptions` |
| Fingerprints of each still and digests of each file, compared into duplicate groups | `Finding duplicates` |
| An Immich account | `Syncing “Home”`, the account's sidebar glyph; L3 `Connecting to the server` while it connects, then how far its pass is (Progress); a pass that ended shows only what stops the account and the assets its server has not read yet |

Not listed, because each has its own surface (one fact, one owner): an import (the import
bar), Move to Trash (the trash status bar), export and reorganization (their sheets and
alerts), and a loupe's download (its pane). Not listed, because they are machinery rather
than an outcome: the grid's publications, the People gallery's tally, the derived folder's
launch tidy.

## Scope lines

A scope whose result is still being built says so in its own bar (DES-125), so the answer to
"why isn't it all here?" sits where the question is asked:

| Scope | Line |
| --- | --- |
| People | L3 `1,820 photos not yet checked for faces` (DES-109) |
| Search | the empty state's `Otos is still reading 1,204 items for search…` (DES-108) |
| Duplicates | L3 `Still looking for duplicates` while nothing would move and the groups are still being built |

## Strings

| String | Level |
| --- | --- |
| `Working on N things` / `Waiting on N things` / `Up to date` | popover L1 |
| what a piece of work does | L2 |
| what is left, the downloads it waits on, what stops it, `and N more`, `Everything else is up to date` | L3 |
| `Open Settings…` | a row's act |
| `Still looking for duplicates` | duplicates bar L3 |
