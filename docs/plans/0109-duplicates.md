# Plan 0109: Duplicates, card checksums, and Trash that can be put back

Opened 2026-10-31 from the design study `docs/research/2026-10-31-duplicate-detection.md`
(design v2 and its two adversarial reviews). The owner approved it the same day, with
three additions:

- **Bursts are never duplicates.** A "Same photo" group means one capture saved as
  several files, never several captures that look alike. Three gates enforce it
  (increment 5).
- **Move to Trash can be put back after a relaunch, edits included,** and items still
  pending can be withdrawn after a relaunch (increment 1).
- **No single-letter shortcuts** for the Duplicates actions: menu items, buttons and
  VoiceOver actions only. The owner's library calibrates the Same-photo threshold
  (increment 0).

Each increment lands on `main` through its own PR with full `script/check.sh` evidence,
updates the requirement rows, ADRs, design rules and `docs/architecture.md` it changes,
and ends with the CLAUDE.md DoD. Increments 1–3 do not depend on the Duplicates surface
and land first.

## Agreed product behavior

- **Identical** groups are files with the same XXH3-128 digest and size. Both
  signatures must be current, both rows in a reachable, fully enumerated root, and
  neither row pending trash. Images and videos.
- **Same photo** groups are stills only. A difference hash of the stored thumbnail
  proposes a candidate; a pixel comparison then confirms it; three gates exclude separate captures.
  Same-photo groups are never preselected.
- **Preselection.** Otos marks copies to move only in an Identical group that sits inside
  one library, where at most one copy carries authored overlay (curation, edit) or
  `.xmp` / `.srt` companions. That copy is kept. Otherwise the keeper is the copy whose
  name has no Finder or browser copy suffix, then the earliest birth date, then path
  order. Every other group waits with `Choose a copy to keep`.
- Two libraries sharing many identical items show as one summary row per library pair,
  with `Keep Both Libraries`. Nothing across libraries is preselected.
- The **Duplicates** row sits at the end of the sidebar. It appears with the first group
  and stays while selected, showing `No duplicates`.
- The surface is a list of groups. Each row shows location first, then filename, then
  dimensions · size, then marks, then its state as a symbol plus text. Rows are the
  selection.
- Commands are **Photo ▸ Keep This Copy**, **Move This Copy to Trash** and **Keep All
  Copies**, all undoable, each with a matching VoiceOver custom action. Return opens
  Compare or Loupe with the group as the filmstrip.
- The bottom bar's L1 is `140 photos with duplicates`, with L3 facts one clause each.
- The bulk act is a plain button, `Move 312 Items to Trash`, with no Return equivalent.
  It acts on exactly the groups on screen. Groups found later wait behind `N more found`.
- Undo restores the moved items, reselects Duplicates and reveals the first restored
  group.
- **Cards** are checksummed while idle, behind thumbnails. An import never waits for
  that. The staged copy is still hashed, and compared with the card's digest when one
  exists. Card items whose content a library already holds are skipped by the plan.

## Increment 0 — Measurements (research only)

1. **Staged-hash cost.** Time the import worker's copy and its `ContentHash` interval
   separately for one real card import. Report `op=contentHash owner=import`
   `elapsedMs`/`mbps` against copy time per entry, and whole-run wall time with and
   without hashing on the same card. This decides whether increment 2 overlaps the
   staged hash with the next copy (only if the hash measurably limits throughput).
2. **Same-photo calibration** — done 2026-10-31 in
   `docs/research/2026-10-31-duplicate-calibration.md`: the feature print is dropped;
   dHash ≤ 10 plus 32 × 32 MAD < 4 finds 89 % of synthetic copies with no unrelated
   match; static bursts are separated only by capture sub-seconds. The original method
   follows. Calibration on the owner's library. Run a throwaway probe over stored
   thumbnails only (Application Support), reading no originals. For each pair the probe
   records:
   - feature-print rev-2 distance;
   - aligned-thumbnail pixel difference;
   - capture instant, sub-seconds, body serial, shutter count and BurstUUID, where
     present.

   Label sets: known resized and re-saved copies; burst sequences; brackets; edited
   exports; screenshots. Choose the two thresholds so that **no two frames of one burst
   or bracket group**, and report recall on known copies.
3. Write `docs/research/2026-11-…-duplicate-calibration.md` with the probe, data and
   chosen thresholds.

## Increment 1 — Trash that can be put back (landed)

Landed as the simpler shape the code allowed: the trashed item's **row is kept**, hidden,
with the Trash path `trashItem` reported (`media_asset.trash_path`, schema v10), instead of
a separate trashed-record table. A file seen again at the row's own path (Finder's Put Back,
also after a relaunch, or undo) shows the row with all its overlay. A scan purges the row
only once the Trash no longer holds the file. The undo-time overlay snapshot is gone. The
trash bar gained `Cancel`, which withdraws every pending item from the rows themselves.
Recorded in ADR 0022, ADR 0008, ARC-058, APP-039, DES-089 and `trash-status-bar.md`.

## Increment 2 — Card checksums

- **Hash-required removable volumes.** `.removableVolume` roots become hash-required in a
  second claim phase. A card row is offered for its digest only when no row of that card
  needs metadata or a thumbnail.
  - The claim indexes and `stalenessSQLPredicate` gain a removable hash phase.
  - ENR-017's bracket withdraws hashing claims with the rest.
  - Eject quiesces them through the existing claim release. `ContentHasher`'s
    `shouldContinue` stops a file mid-read.
- **Verify the staged copy.** The import worker still hashes the staged copy. When the
  source row's digest is current for the copied size and mtime, the two are compared. A
  mismatch fails that entry with a logged reason
  (`op=mediaOperation.entry phase=failed reason=digestMismatch`) and publishes nothing.
  If increment 0 shows the staged hash limits throughput, overlap it with the worker's
  next copy, still verified before publish.
- **Docs to update:**
  - ADR 0018 (rewrite: every root enrichment reads is hashed; the staged comparison);
  - ENR-013, ENR-017, ENR-018 (whether fresh import rows outrank queued work is
    restated as measured, not assumed);
  - ARC-053.
- **Tests:**
  - card digests are produced only after the card's thumbnails;
  - no card hashing while an import reads it;
  - an eject mid-hash publishes nothing;
  - a corrupted staged copy (injected byte flip) fails its entry;
  - Import pressed before hashing ends imports everything.

## Increment 3 — Import knows what the libraries hold

- **Skip content matches.** Import planning takes the card's current digests as values
  in its snapshot. A card item whose digest matches an Identical-eligible library row is
  skipped by the plan, and L1's `new` count excludes it.
  - The match counts only rows that are reachable, fully enumerated, current and not
    pending trash.
  - Matches found after Ready wait for the next plan. A pressed Import imports the plan
    it showed.
- **Import bar copy** (`import-bar.md`, DES-034/035). Path matches and content matches
  share one clause:
  - `139 already in Summer Photos`;
  - `… in your libraries` when the matches span libraries.
- **Erase.** The alert's path-proven sentence is unchanged. A content-matched item is
  erasable only if its matching library row is re-checked at erase time as current,
  reachable and not pending trash (APP-032, ADR 0026).
- **Docs to update:**
  - ADR 0018, 0019 and 0026;
  - APP-029, APP-032;
  - `docs/design/import-bar.md`.
- **Tests:**
  - renamed library copy → skipped;
  - match only in a pending-trash row → imported;
  - match only in an offline root → imported;
  - Ready counts stable while hashing completes;
  - Erase refuses an item whose match went pending trash after planning.

## Increment 4 — Identical duplicates

- **Owner.** Store answers duplicate groups as a query over digests. `CatalogProjection`
  derives the groups, keepers, waits and library-pair summaries off the MainActor and
  publishes them as part of `CatalogWindowState` for the Duplicates scope.
  `CatalogWindowViewModel` assigns them. Views stay passive.
- **Durable state, both overlay (ADR 0008):**
  - the user's per-copy Keep / Move choices within a group;
  - kept-together memory, stored per pair of paths so a later copy is the only one
    offered. Rows carry it through `ON UPDATE CASCADE` on Otos moves and on witnessed
    moves, and it is purged with either row.
- **Keeper rule** as agreed, a pure function with table tests. The rule's inputs are
  values: names, birth dates, library, overlay presence, companion presence.
- **Surface:**
  - sidebar row (APP-002);
  - list with `.isHeader` sections;
  - a collapsed `Kept` section;
  - the bar per design v2: plain button, frozen on-screen set, `N more found` and `Show`,
    `6 need your choice` and `Show`, the honest download and not-checked lines;
  - menu items and VoiceOver custom actions;
  - Return → Compare/Loupe on the group;
  - ⌘⌫ on a kept row returns its group to waiting.
- **Act.** One queue intent over the marked items. One undo group, `Undo Move to Trash`,
  reveals the first restored group. `Keep All Copies` is undoable.
- **Docs and rules:**
  - a new ADR: duplicate groups are a projection over digests and authored overlay;
    kept-together memory is overlay;
  - new APP rows;
  - `docs/design/duplicates.md` (per-screen spec);
  - DES-052 (records the plain-button deviation);
  - DES rules for the row state marks;
  - `docs/architecture.md`.
- **Instrumentation.** `op=duplicates.groups` with counts per kind and wait reason;
  projection signposts.
- **Design check (lens C).** Screenshots in light and dark, grayscale, keyboard-only,
  and Reduce Motion.

## Increment 5 — Same photo

- **MediaMetadata first (ADR 0039).** The library must report capture sub-seconds — the
  one fact that separates a static burst in the owner's library (calibration note) —
  plus body serial, shutter count, and Apple MakerNote BurstUUID / ContentIdentifier.
  Ship whatever it lacks there, then bump. Otos stores what it reports, as reported.
- **Render signature overlay.** A 64-bit dHash and a 32 × 32 grayscale render of the
  stored thumbnail are produced in enrichment after the thumbnail. They read no original
  bytes and need no revision beyond the thumbnail's own.
- **Candidates and confirmation:**
  - Candidates are pairs whose dHash is within Hamming 10 and whose display-geometry
    aspect ratio matches.
  - Confirmation is the 32 × 32 mean absolute difference below 4 (0–255). Both
    thresholds were measured on previews; the tests re-measure them on thumbnails before
    they ship.
  - Images are never compared with videos. `isUtility` images are excluded.
- **Burst gates:**
  1. Two files with capture metadata that differ in sub-seconds, shutter count or
     BurstUUID, or that come from different bodies, are different captures. They are
     never grouped.
  2. Confirmation needs pixel near-identity, not similarity.
  3. A copy without capture metadata joins only the one original clearly closer than
     every other. If two candidates are about equally close, nothing is grouped.

  A RAW and a processed file with the same capture instant, sub-seconds and serial are a
  pair, never a group.
- **Behavior.** Same-photo groups join the Duplicates list, never preselected.
- **Docs to update:** ADR (the increment 4 ADR extended), ENR row for the print, APP
  rows, `docs/design/duplicates.md`.
- **Tests:**
  - burst fixtures never group;
  - a resized and EXIF-stripped copy groups with its source;
  - an ambiguous stripped copy groups with nothing;
  - RAW+JPEG and HEIC/JPEG pairs never group;
  - the signature is produced from the stored thumbnail without reading the original.

## Closure

Delete this plan when increment 5 lands, and record its decisions in
`docs/plans/README.md`. The roadmap note about ADR 0018's removable-volume digest gap is
removed in increment 2.
