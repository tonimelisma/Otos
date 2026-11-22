# Activity

The surface that says the status of Otos's background work — working, waiting on something,
or up to date — and never when it ran (ADR 0058,
DES-124). Most of Otos's work runs unasked, over hours on a large cloud library: reading each
photo, downloading originals, finding faces, naming places, preparing search, describing
photos, looking for duplicates, syncing an Immich account. None of it belongs to a sidebar
selection, so no bar at the bottom of the content pane can own it (DES-040). It has one
place: a line at the foot of the sidebar, and the popover it opens.

## L1 primary fact

The popover: `Working on 3 things`, else `Waiting on 2 things`, else `Up to date`.

## The line

At the sidebar's foot, under every section, behind a hairline, on the sidebar's own color,
at one fixed height in every state (DES-053): a 16 pt glyph level with the L2 line, then L2
over L3. A line with no L3 is centred in that height, so `Up to date` sits level with its
checkmark.

| State | Glyph | L2 (`body`) | L3 (`subheadline`) |
| --- | --- | --- | --- |
| Before the window's work is watched (the first grid has not painted) | none | blank | blank |
| Something working | small spinner (DES-072) | the one that has worked longest (`Finding faces`) | `and 2 more`, or none |
| Nothing working, something waiting | `pause.circle`, secondary | what waits, named (`Descriptions: waiting to try again`) | `and 1 more`, or none |
| Nothing working or waiting | `checkmark`, secondary | `Up to date` | none |

The line names the work that started first, so a short job that starts beside a long one
changes only the count. Clicking it, or Space / Return on it with Full Keyboard Access, opens
the popover; it is disabled while nothing is known. VoiceOver reads `Activity, Finding faces,
and 2 more`.

## The popover

Read-only inspection (DES-041), 320 pt wide, anchored to the line's trailing edge: the L1
header, then one row for every piece of work, in a fixed order, each Immich account after.
A row is the work's glyph, its L2 name, its L3 status under it, and the status's glyph at the
trailing edge, level with the name:

| Status | L3 | Trailing glyph |
| --- | --- | --- |
| Working | `Working`, with the one exact count Otos holds (`Working, 8,412 photos to check`) | small spinner |
| Waiting | what it waits on: `Paused while memory is low`, `Paused while the Mac cools down`, `Paused in Low Power Mode`, `Waiting to try again` | `pause.circle` |
| Up to date | `Up to date` | `checkmark` |

No row shows a time: the surface answers "is it done, working, or waiting", not "when"
(owner, 2026-11-21). A count appears only where Otos holds an exact one (DES-031): People's
unchecked tally. Nothing claims a
percentage, a remaining time or a total.

## Names

| Work | Row name | Line while working |
| --- | --- | --- |
| Thumbnails, previews, each item's details and its digest | `Photos` | `Reading photos` |
| Originals from a cloud provider | `Originals` | `Downloading originals` |
| Details re-read after Otos learned to read more | `Photo details` | `Updating photo details` |
| Faces in stills and video frames | `Faces` | `Finding faces` |
| Faces put together into people | `People` | `Recognizing people` |
| Countries and towns | `Places` | `Naming places` |
| What search reads in each photo | `Search` | `Preparing search` |
| Descriptions | `Descriptions` | `Describing photos` |
| Duplicate groups | `Duplicates` | `Looking for duplicates` |
| An Immich account | its name: `Syncing`, `Connecting` (working), `Waiting for the server` (offline), `Waiting for you to sign in` (signed out), `Up to date` | `Syncing Home` |

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
| a work's name; the line's working name or what waits | L2 |
| a row's status, `and N more` | L3 |
| `Still looking for duplicates` | duplicates bar L3 |
