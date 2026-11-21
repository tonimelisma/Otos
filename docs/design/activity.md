# Activity

The surface that says what Otos is doing in the background, and since when (ADR 0058,
DES-124). Most of Otos's work runs unasked, over hours on a large cloud library: reading each
photo, downloading originals, finding faces, naming places, preparing search, describing
photos, looking for duplicates, syncing an Immich account. None of it belongs to a sidebar
selection, so no bar at the bottom of the content pane can own it (DES-040). It has one
place: a line at the foot of the sidebar, and the popover it opens.

## L1 primary fact

The popover: how many things Otos is working on (`Working on 3 things`), or `Up to date`.

## The line

At the sidebar's foot, under every section, behind a hairline, on the sidebar's own color,
at one fixed height in every state (DES-053): a 16 pt leading glyph, then L2 over L3.

| State | Glyph | L2 (`body`) | L3 (`subheadline`) |
| --- | --- | --- | --- |
| Before the window's work is watched (the first grid has not painted) | none | blank | blank |
| Nothing working | `checkmark`, secondary | `Up to date` | blank |
| One thing working | small spinner (DES-072) | its name (`Finding faces`) | blank, or why it waits (`Paused in Low Power Mode`) |
| More working | small spinner | the one that has worked longest | `and 2 more` |

The line names the work that started first, so a short job that starts beside a long one
changes only the count. Clicking it, or Space / Return on it with Full Keyboard Access, opens
the popover; it is disabled while nothing is known. VoiceOver reads `Activity, Finding faces,
and 2 more`.

## The popover

Read-only inspection (DES-041), 320 pt wide, anchored to the line's trailing edge:

| Zone | Content |
| --- | --- |
| Header | L1 (`title3` semibold): `Working on N things` or `Up to date` |
| Working | one row per thing working, in a fixed order: glyph, L2 name, L3 detail under it (why it waits, or the one exact count Otos holds, `8,412 photos to check`), and at the trailing edge L3 `Since 09:14` |
| Hairline | only when both lists show |
| Finished | one row per thing that finished this session, newest first: glyph, L2 name (`Places named`), and the L3 time it finished (`09:31`, or the day and time when not today). Each Immich account's last sync (`Home synced`) shows here too, from its persisted time |

A time is the moment Otos saw the work start or end, never an estimate. A count appears
only where Otos holds an exact one (DES-031): today that is People's unchecked tally. Nothing
claims a percentage, a remaining time or a total.

## Names

| Work | Working | Finished |
| --- | --- | --- |
| Thumbnails, previews and each item's details | `Reading photos` | `Photos read` |
| Originals from a cloud provider | `Downloading originals` | `Originals downloaded` |
| Details re-read after Otos learned to read more | `Updating photo details` | `Photo details updated` |
| Faces in stills and video frames | `Finding faces` | `Faces found` |
| Faces put together into people | `Recognizing people` | `People recognized` |
| Countries and towns | `Naming places` | `Places named` |
| What search reads in each photo | `Preparing search` | `Search ready` |
| Descriptions | `Describing photos` | `Photos described` |
| Duplicate groups | `Looking for duplicates` | `Duplicates checked` |
| An Immich account's sync | `Syncing Home` | `Home synced` |

Why work waits (ADR 0057): `Paused while memory is low`, `Paused while the Mac cools down`,
`Paused in Low Power Mode`.

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
| `Working on N things` / `Up to date` | popover L1 |
| a work's name | L2 |
| `and N more`, a wait's reason, a count, `Since 09:14`, a finished time | L3 |
| `Still looking for duplicates` | duplicates bar L3 |
