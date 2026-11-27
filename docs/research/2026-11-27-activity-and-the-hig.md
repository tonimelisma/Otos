# The Activity surface against Apple's HIG — 2026-11-27

## Question

The owner, looking at the installed app's Activity popover on his library (2026-11-27):
"explain the status for making thumbnails, it doesn't make any sense. also, why does its
progress bar disappear and reappear all the time", then "why are we showing these to the
user? what does the user care about?". The row read:

```
Making thumbnails
  19,659 of 20,715 photos and videos
  The server didn’t answer for 114 items. Otos will try again.
  The server sends 934 items only when you open them. Otos will try again.
```

## What the code said the row meant

Read from the code, not the owner's logs (a cloud session never reaches his Mac).

- **20,715** was the stretch's total (`ActivityBoard.record`): what enrichment finished
  since the stretch began plus what was left. It named nothing the user knew.
- **1,056 left, 1,048 of them stopped.** The remaining items were almost all the stopped
  ones. Both causes come only from an Immich account: ranged reads go only to an account
  (`ImmichAccounts.rangeAccess`), and `sendsOriginalsOnlyForUserWork` is true only for
  `.immichAccount`. An account row is claimed under `.account` for its metadata and a video's
  faces only (`EnrichmentScope(claim:asset:)`); its thumbnail is the server's. So the row
  named as thumbnails still to make what were details of items already showing thumbnails.
- **"Only when you open them"** is Otos's own rule (ADR 0046 §4), not the server's. A ranged
  read needs the original's size (`EnrichmentCoordinator.byteAccess`), which comes only from
  the stream's `fileSizeInByte` (`ImmichClient`, `AssetExifV1`); a row without one falls back to
  the local file, finds none, and paces as `sentOnlyWhenOpened`. A retry cannot succeed then,
  so "Otos will try again" was a promise no retry could keep. That a missing size is the cause
  for these 934 is a hypothesis: the owner's diagnostics export would confirm it.
- **The flicker.** The board read a kind as working whenever an owner of it was not quiescent.
  Each of ~1,048 paced rows had its own 15-minute pacing (`ledgerPacing`), set at different
  moments, so the ledger's wakes were staggered: each made enrichment busy for a moment —
  spinner and bar — and its failed retry left it quiescent again — pause glyph, no bar.

## The HIG

Read from Apple's own pages (developer.apple.com/design/human-interface-guidelines, the
JSON behind them) on 2026-11-27.

- **Feedback**: "it often works well to display status information in a passive way so that
  people can view it when they need it"; "because people typically expect their action or
  task to succeed, they only need to know when it doesn't"; "Show people when a command
  can't be carried out and help them understand why."
- **Progress indicators**: "Be as accurate as possible when reporting advancement";
  "Keep progress indicators moving so people know something is continuing to happen. People
  tend to associate a stationary indicator with a stalled process or a frozen app. If a
  process stalls for some reason, provide feedback that helps people understand the problem
  and what they can do about it"; "Don't switch from the circular style to the bar style";
  "Display a progress indicator in a consistent location"; "Avoid vague terms like loading or
  authenticating"; on macOS, "Prefer an activity indicator (spinner) to communicate the
  status of a background operation".
- **Writing**: "Write clear error messages … display it as close to the problem as
  possible, avoid blame, and be clear about what someone can do to fix it"; "If you find that
  language alone can't address an error that's likely to affect many people, use that as an
  opportunity to rethink the interaction"; "avoiding jargon".

## What a user cares about

1. Is my library all here — every photo showing, people found, search and descriptions
   ready?
2. Is something wrong that I need to fix — signed out, disk full, Apple Intelligence off?
3. Roughly, is Otos busy, and is it getting there?

Not: retries, ranged reads, rows owed details, a stretch's total.

## Conclusions (built in the same increment, ADR 0058)

- Rows are outcomes the user would notice missing. `Making thumbnails` became `Showing
  photos` — the rows whose tile shows a placeholder — and `Reading details`, everything else
  enrichment reads of items already showing, listed only while it works. Downloads became the
  line of the row they serve.
- A problem has a standing (`OwnerTrouble.Standing`): what the user can fix is said first,
  on the line too; a source or service that is unavailable is said and named; one item's
  failure retried on its own is never said; an item only the user's work can read is no work
  left. The failures not said stay in the logs.
- A row says what is left (`1,056 photos and videos left`); the bar keeps the stretch's exact
  fraction.
- A kind works only while an owner moves its work: busy with items left that are not parked.
  A waiting kind keeps waiting through its owners' retries until an item finishes, so a
  failed retry changes nothing on screen.
- A row draws one indicator: its bar while it works, a spinner only with nothing counted, a
  warning while it needs the user, none while it waits. The trailing `pause.circle` that looked
  like a button went.

Left out, with the reason: a Cancel or Pause control for background work (HIG: "When it's
feasible, let people halt processing"). Halting loses nothing, and Otos already holds its
work for memory, heat and Low Power Mode (ADR 0057); no owner asked for one. A System Settings
button for Apple Intelligence: no deep link into its pane could be verified from a cloud
session, so the row says where to go in words.

## Second pass: the names (same day)

The owner, reading the first pass's names: "So showing photos is not showing photos is it? And
Finding people, is it actually finding people? Or detecting faces or what? And naming places?
… Reading details is also incredibly obscure. Read apple hig and come up with new
suggestions." Each name was checked against what its code does:

- `Showing photos` made thumbnails; `Reading details` was three jobs — Info's details, the
  digests duplicates are told by, thumbnails remade.
- `Finding people` was mostly face detection (Apple Vision on previews and video frames),
  then grouping. Apple's Photos counts the same work as photos "scanned" (Apple Support
  Community threads quote its "0 photos scanned").
- `Naming places` counted map cells, not photos.
- `Preparing search` made each item's search embedding: nothing is identified or labelled.

HIG Writing asks for "words that are easily understood and convey the right thing" and verbs
in labels; Progress indicators: "Avoid vague terms". So each row became a verb and the thing
Otos makes: `Making thumbnails`, `Reading photo info`, `Scanning for faces`, `Looking up place
names` (`locations`), `Indexing for search` (macOS's own word for Spotlight's), `Writing
descriptions`, `Finding duplicates`, and an account `Syncing “Home”`. Enrichment's work is
filed under the outcome it serves (`EnrichmentPurpose`), and an account's rows never count as
thumbnails, which its sync brings.

Sources: [Check the status of your library in Photos for macOS](https://support.apple.com/119921);
[0 Photos Scanned](https://discussions.apple.com/thread/254493558).
