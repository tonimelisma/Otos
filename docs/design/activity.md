# Activity

The surface that says what Otos's background work is doing — working, or stuck and why —
and never when it ran (ADR 0058,
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
| Something working | small spinner (DES-072) | the one that has worked longest (`Finding people`) | `and 2 more` (the popover's other rows), or none |
| Nothing working, something paused or stuck | `pause.circle`, secondary | what waits (`Describing photos`) | `and 1 more`; for one row alone, the first sentence of what stops it (`Apple Intelligence isn’t responding`) |
| Nothing working or waiting | `checkmark`, secondary | `Up to date` | none |

The line names the work that started first, so a short job that starts beside a long one
changes only the count. Clicking it, or Space / Return on it with Full Keyboard Access, opens
the popover; it is disabled while nothing is known. VoiceOver reads `Activity, Finding people,
and 2 more`.

## The popover

Read-only inspection (DES-041), 320 pt wide, anchored to the line's trailing edge: the L1
header, then one row for each piece of work that works, is paused or is stuck, in a fixed
order, each Immich account after, then `Everything else is up to date` in L3 when anything
watched is not listed. With nothing working or waiting, the header alone. A row is the work's
glyph, what it does (L2), each thing that stops it as its own L3 line under it, and the
status's glyph at the trailing edge, level with the name:

| Status | L3 | Trailing glyph |
| --- | --- | --- |
| Working | what stops some of its items, if anything; else the one exact count Otos holds (`8,412 photos to check`); else nothing | small spinner |
| Paused | the machine condition (`Paused while memory is low.`, `Paused while the Mac cools down.`, `Paused in Low Power Mode.`), then what stops it | `pause.circle` |
| Stuck | what stops it | `pause.circle` |

What stops work is said in sentences: what is wrong, then what happens next or what to do
(HIG, Progress indicators: a stalled process says what the problem is and what people can do
about it). Its owner names the cause (`OwnerTrouble`, ADR 0058); nothing says only
"waiting".

| Cause | L3 |
| --- | --- |
| Downloads failed | `11 items didn’t download. Otos will try again.` |
| Disk full | `The disk is almost full. Otos will go on when there’s room.` |
| A server did not answer | `The server didn’t answer for 2,999 items. Otos will try again.` |
| A source sends originals only when opened | `The server sends 12 items only when you open them. Otos will try again.` |
| Faces unread | `Faces in 3 items couldn’t be read. Otos will try again.` |
| Face model missing | `The face finder couldn’t start. Otos will try again.` |
| Apple Intelligence off | `Turn on Apple Intelligence in System Settings to describe photos.` |
| Mac not eligible | `This Mac can’t run Apple Intelligence.` |
| Model not ready | `Apple Intelligence isn’t ready yet. Otos will try again.` |
| Model service failing | `Apple Intelligence isn’t responding. Otos will try again.` |
| Model busy | `Apple Intelligence is busy. Otos will try again.` |
| Descriptions failed | `4 items couldn’t be described. Otos will try again.` |
| Cloud provider failing | `The cloud provider isn’t answering. Otos will try again.` |
| Place names failed | `Place names couldn’t be looked up. Otos will try again.` |
| Search failed | `Search couldn’t be updated. Otos will try again.` |
| Account offline | `The server isn’t answering. Otos will try again.` |
| Account signed out | `You’re signed out of this account.` |

No row shows a time: the surface answers "is it done, working, or stuck", not "when"
(owner, 2026-11-21). A count appears only where Otos holds an exact one (DES-031): People's
unchecked tally, and the items a trouble stops. Nothing claims a percentage, a remaining time
or a total.

## Names

Each row says what the work does, in words a user knows (DES-035); a user cannot tell
reading a photo from re-reading its details, or finding a face from recognizing its person,
so each pair is one row.

| Work | Row and line |
| --- | --- |
| Thumbnails, previews, each item's details and its digest, read again after Otos learned to read more | `Reading photos` |
| Originals from a cloud provider | `Downloading photos` |
| Faces in stills and video frames, put together into people | `Finding people` |
| Countries and towns | `Naming places` |
| What search reads in each photo | `Preparing search` |
| Descriptions | `Describing photos` |
| Duplicate groups | `Looking for duplicates` |
| An Immich account | `Syncing Home`; L3 `Connecting to the server` while it connects |

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
| what stops it, a count, `and N more`, `Everything else is up to date` | L3 |
| `Still looking for duplicates` | duplicates bar L3 |
