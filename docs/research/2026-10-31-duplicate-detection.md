# Duplicate detection: competitors, patterns and a design study

Date: 2026-10-31. A research pass and a design study. No code or behavior changed, and
nothing here is a requirement: the design below is a proposal for the owner to accept,
change or reject before any plan is written.

Labels: **[D]** documented by the vendor or Apple; **[E]** reported by users or
reviewers; **[M]** measured on this Mac with a throwaway probe (small n); **[U]**
unverified or inferred.

## Question

What would a duplicate feature for Otos look like if it found real duplicates with no
false alarms worth worrying about, chose the copy to keep by itself wherever that can be
done safely, and let the user clear a library of extra copies in one act without fear?

## Competitors

| App | What it matches | Keeper by default | Removal | Notable |
| --- | --- | --- | --- | --- |
| Apple Photos (Utilities ▸ Duplicates) | Exact copies and "effectively identical" copies (stripped metadata, other size) [D]; crops and B&W edits also land in groups [E] | "Highest quality version", metadata combined into it [D] — but the UI never shows which copy survives [E] | Merge N Items → confirm → Recently Deleted, 30 days [D] | Most cited complaint: it kept the lower-quality JPEG over the TIFF/master [E] |
| Lightroom Classic 15.4 (June 2026) | Exact pixel matches; edits and metadata differences still match [D/E] | Earliest version on top of a stack; change via unstack ▸ Set as Original [E] | Remove from catalog or delete from disk | 15.4 deleted *every* photo in the Duplicates view on Delete Rejected; pulled and fixed in 15.4.1 [E]. A reviewer found 15 of hundreds [E] |
| Lightroom (cloud) Assisted Culling | Bursts and similar shots, stacked | Aesthetic ranking leads the stack | Nothing removed | Stated principles: "assist, don't decide", "when in doubt, keep it" [D] |
| Mylio Photos | DeDupe: exact only. DeClutter: similar shots in a 2 s window, same aspect, same camera serial [D] | AutoMark by a user-ordered priority list (ratings, edits, folders) [D] | System Trash; metadata merged by priority, keywords and albums unioned [D] | "If there's any doubt … Mylio won't delete it" [D] |
| Gemini 2 | Two bins, Duplicates and Similars [D] | Exact duplicates auto-selected; Similars never preselected [D] | Trash | "Learns your choices" makes selection opaque [U] |
| Immich | CLIP embedding on the preview image, cosine ≤ 0.01 by default, images only against images [D] | Largest file, then most EXIF fields [D] — called naive: the smaller file often has richer EXIF [E] | Trash; albums/tags unioned, favorite if any, best rating, GPS only if all agree [D] | Sunsets and similar sports videos grouped [E]; 65 000-group queue with no accept-all [E] |
| digiKam | Haar-wavelet similarity with a % range [D] | "Older or larger", or prefer a chosen folder [D] | Remove Duplicates spans the whole result set [E] | No "not a duplicate" memory [E] |
| PhotoSweeper, Duplicate Photos Fixer | Slider from identical to bursts [D] | Reorderable rule list; locked items [D] | Trash, Lightroom reject flag, or a Photos album | Rules buried in Preferences, rescan per change; defaults swept in screenshots [E] |
| Excire, Synology, PhotoPrism, Google Photos | Exact, near, series (Excire); PDQ hash in ±12 h (Synology); checksum skip at index (PhotoPrism, Google) [D] | — | Stack only, or silent skip | Excire can ignore RAW+JPEG pairs [D]; Synology: "a screening assistant, not a boss" [D] |

Sources: Apple <https://support.apple.com/guide/photos/remove-duplicates-pht5a3157c1d/mac>,
Macworld <https://www.macworld.com/article/1366211/how-to-use-duplicate-detection-apple-photos.html>,
Apple Community <https://discussions.apple.com/thread/256021424>,
Adobe <https://community.adobe.com/announcements-673/lightroom-classic-v15-4-is-live-cull-people-shots-faster-auto-detect-duplicates-sync-keywords-everywhere-1627070>,
Lightroom Queen <https://www.lightroomqueen.com/whats-new-in-lightroom-2026-06/>,
FotoFlow <https://www.fotoflowsolutions.com/life-in-focus/tag/de-dupe>,
Adobe Design <https://adobe.design/ideas/behind-the-design-assisted-culling-in-adobe-lightroom>,
Mylio <https://manual.mylio.com/topic/find-duplicate-photos>,
<https://manual.mylio.com/24.3/en/topic/find-similar-photos>,
MacPaw <https://macpaw.com/support/gemini/knowledgebase/gemini-2-duplicates-similars>,
Immich <https://docs.immich.app/features/duplicates-utility>,
<https://docs.immich.app/administration/system-settings/>,
digiKam <https://docs.digikam.org/en/maintenance_tools/maintenance_duplicates.html>,
<https://discuss.kde.org/t/i-really-wish-there-was-a-mark-as-not-duplicate-s-option-in-the-duplicates-similarity-tool/47866>,
PhotoSweeper <https://apps.apple.com/au/app/photosweeper/id463362050?mt=12>,
Excire <https://excire.com/en/tutorials/excire-search-2024/duplikatefinder/>,
Synology <https://blog.synology.com/photossimilar/>,
PhotoPrism <https://docs.photoprism.app/user-guide/library/duplicates>.

### What recurs, and what fails

- **Two tiers of sameness, handled differently.** Exact copies are one job, similar
  shots another (Mylio DeDupe vs DeClutter, Gemini Duplicates vs Similars). Where a
  tool preselects, it preselects only exact copies.
- **Similar shots are stacked, not deleted** (Google, Synology, Lightroom, Immich).
  Choosing the best frame of a burst is culling, not de-duplication.
- **A stated keeper rule plus a manual override** beats a hidden "best quality" pick.
  Apple's hidden choice is the most common complaint in the whole category.
- **Recoverable removal** is universal: Recently Deleted, system Trash, a reject flag.
- **The failure modes:** a hidden keeper; naive "biggest file wins"; edits, crops and
  bursts treated as duplicates; one-group-at-a-time queues that cannot scale; a bulk
  act with a wider blast radius than shown (Lightroom 15.4, digiKam); no memory of "not
  a duplicate"; silent skips the user cannot audit; settings away from results.

## Detection technology on Apple platforms

- **Byte identity.** Otos already stores XXH3-128 with its `(size, mtime)` signature
  for fixed-library and device-staging bytes (ADR 0018). Equal size is a free
  pre-filter; equal digest is proof. Removable sources are never hashed in place.
- **Vision feature print**, revision 2 (the only revision the Swift API exposes on
  macOS 27): 768 floats, unit-normalized, Euclidean distance in [0, 2] [M]. Measured on
  system wallpapers [M]: identical 0; half-size copy 0.005; 10 % crop 0.166; +0.15
  brightness 0.190; same design in another colour 0.43; unrelated 0.90–0.95. About
  10 ms per already-decoded thumbnail [M]. Resolution barely moves the distance, so the
  print can be computed from Otos's stored thumbnail and never needs the original's
  bytes. Apple publishes no threshold, and distances are not comparable across
  revisions (<https://developer.apple.com/forums/thread/721760>), so the revision must
  be stored with the print. The print is semantic: Apple's own demo retrieves *other*
  coffee-shop scenes for a coffee-shop photo
  (<https://developer.apple.com/videos/play/wwdc2019/222/>), so a loose threshold groups
  different moments of one scene.
- **Immich's default** (cosine ≤ 0.01 ≈ Euclidean 0.14 on a unit vector) sits at the
  10 %-crop point — tight, and still reported to group similar sunsets [E].
- **Perceptual hashes** (dHash, pHash) are deterministic across OS versions but are
  defeated by a ~10 % crop (<https://www.hackerfactor.com/blog/index.php?/archives/529-Kind-of-Like-That.html>).
- **Metadata signals** (from MediaMetadata, ADR 0039): capture instant with sub-seconds,
  camera model and body serial, pixel dimensions; Apple MakerNote BurstUUID and
  ContentIdentifier (<https://exiftool.org/TagNames/Apple.html>).
- **Quality signals** — `CalculateImageAestheticsScoresRequest` (`isUtility` flags
  screenshots and receipts), face capture quality (WWDC19: comparative only, "should
  not be compared against a threshold"), Laplacian variance — are ranking hints within
  a burst, which is culling and out of scope below.

## UX and platform evidence

- Raskin: "Never use a warning when you mean undo"
  (<https://alistapart.com/article/neveruseawarning/>). NN/g: confirmations habituate;
  reserve them for rare, serious, irreversible acts
  (<https://www.nngroup.com/articles/confirmation-dialog/>).
- Defaults are accepted unreviewed, and position bias survives a wrong ranking
  (<https://www.nngroup.com/articles/the-power-of-defaults/>). A preselected keeper will
  be trusted, so it may be preselected only where it is provably safe.
- Trust should be calibrated, not maximized: show *why* items grouped (Lee & See 2004,
  <https://pubmed.ncbi.nlm.nih.gov/15151155/>).
- HIG: no alerts for common undoable actions even when destructive
  (<https://developer.apple.com/design/human-interface-guidelines/alerts>); undo names the
  result and shows what it restored
  (<https://developer.apple.com/design/human-interface-guidelines/undo-and-redo>); a
  sheet is for brief, occasional tasks, not repeated act-and-observe work
  (<https://developer.apple.com/design/human-interface-guidelines/sheets>); task options
  live in the view they affect, not in Settings
  (<https://developer.apple.com/design/human-interface-guidelines/settings>); avoid
  relayout while people interact except in response to their own act
  (<https://developer.apple.com/design/human-interface-guidelines/collections>).
- Apple's own precedent: a **Duplicates** row under **Utilities** in the Photos sidebar,
  present only when there is something in it.

## Otos constraints the design must respect

- Identity is the path; Otos invents no durable IDs or fingerprints of identity
  (ADR 0008). A content digest is overlay, not identity (ADR 0018).
- Originals change only through explicit user acts; the only removal is Move to Trash,
  which needs no confirmation and is undone with ⌘Z (APP-027, APP-039, DES-076), except
  the >100 MB cloud-download question (APP-045, DES-090).
- Cloud placeholders: a digest exists only after enrichment has read the bytes, so
  duplicates are knowable only among checked items. Trashing a dataless file needs a
  download first (APP-045). A dataless file's size is cloud storage, not local disk.
- RAW and JPEG of one capture are two cataloged assets, paired only as companions for
  `.xmp`/`.srt` (media companion rows); they are not duplicates.
- Authored overlay (curation, edit recipes) is per asset. Trashing a copy purges its
  overlay once the deletion is proven.
- The grid tile shows no filename (APP-006). For two byte-identical copies the picture
  is the same; the only thing that differs is *where* each one lives and what Otos holds
  for it.

## Design (v1, before review)

### The job

"Clear out the extra copies of photos and videos I already have, and never lose the
one I care about." Choosing the best frame of a burst is a different job — culling —
which Otos already serves with Compare and Liked / Disliked. This feature does not
group similar shots.

### Two kinds of duplicate

1. **Identical** — same XXH3-128 digest and size, both signatures current. Proof, not
   judgement. Images and videos.
2. **Same photo** — different files of one picture: resized, recompressed, re-exported,
   metadata stripped. Images only. All of: feature-print distance below a calibrated
   threshold (starting near 0.05, the resized-copy band, to be measured on a real
   library); the same aspect ratio within 1 %; and, where both carry a capture instant,
   the same instant to the second. A RAW and a processed file sharing directory and stem
   are a pair, never a group.

Cards and cameras are not shown in Duplicates: a card is a source, and the place to
deal with a card's copies is its import (below).

### Card checksums: closing the ADR 0018 gap

Today a `.removableVolume` row is never hashed (ADR 0018), so a card's photos cannot be
matched by content against the libraries, and an import pays a full sequential re-read of
every staged copy inside the import worker (`MediaImportExecutor`, `ContentHash`
interval) before it can publish. The proposal reverses both:

- **Cards are checksummed while they sit idle.** `.removableVolume` roots become
  hash-required in enrichment, in a second, lower phase: a card row is offered for its
  digest only once every row of that card has current metadata and a thumbnail, so
  hashing never delays what the user sees. The card is local, so this downloads nothing.
  ENR-017 already withdraws a card from enrichment while an import reads it; the same
  bracket withdraws its hashing, and an eject quiesces it like any card claim (the hasher
  already takes `shouldContinue`).
- **An import never waits for a checksum.** The import worker stops hashing the staged
  copy. A copy whose source carries a digest current for the size and mtime the import
  copied inherits it with the rest of the reused overlay (ARC-053's stamp rule, which
  already treats the copy as the source file). A copy without one is published without a
  digest and hashed by ordinary enrichment of the destination library, which claims fresh
  import rows first (ENR-018) while their bytes are still local. Nothing in the import's
  critical path reads a byte twice.
- **The import knows what the libraries already hold.** With card digests, import
  planning counts the card items whose digest matches a library row and leaves them out
  of the default selection: the import bar says `312 already in your library` (L3), the
  same way it treats files already at their destination. Items not yet checksummed when
  the user presses Import are imported normally — the button never waits — and any that
  turn out to be duplicates appear in Duplicates afterwards.
- ADR 0018's "byte locality" exclusion of removable volumes goes: a digest is produced
  for every root enrichment reads — fixed libraries (with the deliberate background
  materialization they already get), device staging, and removable volumes. Import
  planning reading the digest is a reversal of
  ADR 0018's "planning reads no hash" and needs the ADR rewritten.

### Where it lives

A **Duplicates** row in the sidebar after the libraries, present only while something
needs review, with a count of groups. It covers every fixed library.

### The surface

Not the photo grid: copies that look identical cannot be told apart by thumbnail. The
Duplicates scope is a list of groups, one section per group:

- Section header: `.headline` kind and count — `Identical · 3 copies` /
  `Same photo · 2 versions` — and `.subheadline` capture date and size.
- One row per copy: 48 pt thumbnail; filename (L2); `Library ▸ folder` (L3); pixel
  dimensions · size (L3); the Liked / Disliked / edited marks it carries; and a **Keep**
  checkbox. The last checked box in a group is disabled — a group always keeps one copy.
- Group trailing button: **Keep All** (remembered for that exact set of copies).
- Return opens the group in Compare (two copies) or Loupe.

### Choosing the keeper (shown, never hidden; no settings)

Identical: the copy carrying authored overlay; if two copies carry different overlay,
the group waits for the user. Otherwise: a name without a Finder or browser copy suffix
(` copy`, ` copy 2`, ` (1)`); then the library earlier in the user's sidebar order; then
the earliest birth date; then path order.

Same photo: preselected only when the largest-pixel copy is in the same format family as
the rest, carries no less capture metadata than any other copy, and no overlay conflicts.
Otherwise the group waits for the user (`Choose a copy to keep`), and nothing in it is
marked.

### The act

A bottom status bar (DES-018): L1 `312 extra copies · 4.2 GB`; L3 `In 140 groups · 6
need your choice`; the act, one prominent button: **Move 312 Copies to Trash**. Groups
waiting for a choice are outside the count until the user chooses. No confirmation;
the act enters the existing trash queue; ⌘Z (`Undo Move to Trash`) restores every copy
and brings their groups back. While checking is incomplete the L3 reads
`Checked 41,200 of 45,000 items` and the count grows as checking proceeds.

## Adversarial reviews of v1

Two independent reviews read v1 cold: one against the HIG and the `DES-*` rules, one
walking personas through it. Claims about code were checked against source. Findings,
most severe first; each is answered in v2.

### User perspective

1. **Data loss — a mirror library is emptied.** "Backup" mirrors "Photos" and sits
   above it in the sidebar; the sidebar-order tiebreak preselects 30 000 groups keeping
   Backup, and the default button empties Photos. Position bias means nobody reads 30 000
   sections; a mirroring sync tool then propagates the deletion.
2. **Data loss — Same photo was preselected,** against the research's own finding.
   Burst frames within one second, ±0.3 EV brackets, mild edited exports and text-heavy
   screenshots can all fall under 0.05; the threshold was calibrated on wallpapers.
3. **Data loss — third-party edits.** Two byte-identical RAWs, only one with a Lightroom
   `.xmp`; the keeper rule sees only Otos overlay and can trash the one with the edit,
   companions included (APP-027).
4. **Data loss — import skip on a doomed match.** A content match in a pending-trash
   row, an offline root, or another library counts as "already in your library", and
   Erase could then delete the card's only good copy.
5. **Data loss — an inherited digest asserts bytes never read.** Without the staged
   hash a copy corrupted by a flaky reader still carries the card's digest (its size and
   mtime match by construction), joins an Identical group, and may be the one kept.
   ADR 0018's "a digest is valid only for the bytes read" is broken.
6. **Major — "hashed while still local" is false.** ENR-018 prioritizes the viewport
   and the `freshly` hand-off, not fresh import rows
   (`EnrichmentCoordinatorWorkSelection.swift`); a large import onto a full disk can be
   evicted first and re-downloaded to hash.
7. **Major — "4.2 GB" is not honest.** Dataless copies, APFS clones and hard links free
   nothing on the Mac, and dataless ones first need the APP-045 download.
8. **Major — overlay on the trashed copy is lost.** Liked or edited on the smaller copy;
   trash undo (APP-039) restores curation, not edits, and does not outlive the session.
9. **Major — Keep All is brittle.** Keyed to the exact set, so a third copy, a rename or
   an Otos reorganization re-raises the group preselected; 200 Print photos need 200
   clicks.
10. **Minor — RAW+JPEG and HEIC/JPEG pairs in different folders** flood "need your
    choice".
11. **Minor — the import count moves while read,** and items imported before hashing
    finished reappear as Duplicates work.
12. **Minor — the aspect check must use display geometry,** or baked-in rotation vs
    EXIF rotation is missed.

### HIG and design system

1. **Blocker — Return has two jobs.** DES-052 binds Return to the prominent button;
   v1 also had Return open a group. HIG Buttons: "Don't assign the primary role to a
   button that performs a destructive action."
2. **Blocker — the row vanishes while selected,** so Undo cannot reveal what it restored
   (HIG Undo; APP-039 selects restored items). Its sidebar position was unspecified and
   its arrival would push rows under the pointer.
3. **Major — the button's count can change before the click lands** (DES-036), and
   inserted groups shift rows under the pointer (HIG Collections).
4. **Major — ⌘⌫ on the keeper row** bypasses the "last Keep is disabled" guard.
5. **Major — Keep checkboxes as Tab stops** make 450+ stops; VoiceOver hears
   "Keep, checkbox" hundreds of times, and filename-first labels do not distinguish
   identical copies whose names match (DES-080, DES-082, DES-085).
6. **Major — no menu-bar commands** for Keep All, Keep This Copy or the bulk act.
7. **Major — Keep All is a permanent, invisible dismissal with no Undo.**
8. **Major — mixed nouns and dishonest bytes:** "extra copies" counts versions too.
9. **Major — checking can stall forever with no reason** when what is left needs a
   download, and its denominator moves with scans (DES-026, DES-031).
10. **Major — the import-bar line breaks import-bar.md:** a second "already" clause
    (DES-034), "your library" where the match may be another library (DES-035), a
    "default selection" Otos does not have, and Ready counts that drop as hashing ends.
    The Erase alert's "already in <library>" is proven by path and must not be borrowed.
11. **Minor —** the disabled button would read `Move 0 Copies to Trash`; "6 need your
    choice" points at nothing; the sidebar count used another unit than the bar; groups
    larger than two have no defined Loupe; two bottom bars need their live-region rules.

Both reviews kept: Identical as proof; the keeper shown on every row; the last Keep
disabled; waiting groups outside the count; Move to Trash with Undo and no alert; a list
rather than the grid, with location shown; similar shots out of scope; prints from stored
thumbnails with their revision; card hashing behind thumbnails, bracketed by ENR-017,
quiesced on eject; no settings.

## Design (v2, after review)

### Detection

- **Identical:** same digest and size, both signatures current, both rows in a
  reachable, fully enumerated root with no pending trash. Images and videos.
- **Same photo** (images only): candidates proposed by a revision-stored feature print
  of the stored thumbnail, then **confirmed** by a deterministic pixel difference of the
  two thumbnails aligned to the same size and display orientation (MediaMetadata
  geometry). Never grouped: two camera originals from the same body that differ in
  sub-seconds, shutter count or BurstUUID (bursts, brackets); any `isUtility` image
  (screenshots, documents); a RAW and a processed file sharing capture instant,
  sub-seconds and body serial in any folder (RAW+JPEG and HEIC/JPEG pairs). The
  threshold is calibrated on a real library before it ships; the wallpaper probe only
  bounds it.
- Similar shots, bursts and brackets stay with Compare and Liked / Disliked.

### Who decides the keeper

Otos preselects only where the choice cannot lose anything:

- The group is **Identical**, every copy is in **one library**, and at most one copy
  carries anything Otos or another app authored for it — Otos overlay (curation, edit)
  or `.xmp` / `.srt` companions. That copy is kept; otherwise a name without a Finder or
  browser copy suffix, then the earliest birth date, then path order.
- Everything else waits with `Choose a copy to keep` and nothing marked: every Same
  photo group, every group whose copies carry differing authored overlay, every group
  spanning two libraries.
- **Library pairs.** When two libraries share many identical items (a mirror), the
  list shows one summary row per pair before the groups — `Backup and Photos share
  29,870 photos` — with `Keep Both Libraries`, which sets the pair aside. The libraries'
  own groups stay reachable under that row. Nothing across libraries is ever preselected.
- A copy marked to move never carries overlay the kept copy lacks, so nothing the user
  authored goes to the Trash with an "extra" copy.

### Where it lives

A **Duplicates** row at the end of the sidebar, after Removable, so its arrival pushes
nothing under the pointer. It appears when the first group is found and stays while it
is selected, showing an empty state (`No duplicates`) after the last group resolves; it
leaves only when the user navigates elsewhere with nothing to review. Its count is the
same unit as the bar's L1.

### The surface

A list, one section per group (header `.isHeader` for VoiceOver):

- Header: `.headline` `Identical · 3 copies` or `Same photo · 2 versions`;
  `.subheadline` capture date.
- Row: 48 pt thumbnail; `Library ▸ folder` first and filename second (the location is
  what distinguishes identical copies); dimensions · size (L3); the curation, edit and
  `.xmp` marks it carries; and the state — `Keep` or `Move to Trash` — as a symbol and
  text, never color alone (DES-029).
- Rows are the selection; the Keep control is not a Tab stop. **Photo ▸ Keep This Copy**
  and **Photo ▸ Move This Copy to Trash** act on the selected rows, with a bare-key
  equivalent chosen in the plan against Lightroom's key map; VoiceOver gets the same two
  as custom actions (DES-085). Row label:
  `Holiday ▸ 2024, IMG_0001.JPG, kept, liked`.
- **Photo ▸ Keep All Copies** (and the section's trailing `Keep All` button, one
  intent) sets the selected groups aside — several at once. It is undoable
  (`Undo Keep All Copies`). It is remembered per pair of paths, and Otos's own moves
  carry it; a later copy is the only one offered as extra. Set-aside groups stay
  listed under a collapsed `Kept` section, so nothing is dismissed invisibly.
- Return opens the selected group in Compare (two copies) or Loupe with the group as the
  filmstrip; Escape returns to its row.
- ⌘⌫ on a kept row is Move to Trash as everywhere (APP-027); its group then returns to
  `Choose a copy to keep`, so the guard holds on every path.

### The act and its numbers

The bottom bar (DES-018) owns the duplicates fact only:

- L1: `140 photos with duplicates` — the sidebar's unit.
- L3, one clause each, as state requires: `312 items marked · 4.2 GB` (file size, the
  trash bar's convention); `2,900 of them are only in OneDrive · 3.1 GB to download`;
  `6 need your choice` with `Show` (scrolls to the first); `3,800 not checked yet ·
  only in OneDrive` when what remains needs a download that is not happening.
- The act: **Move 312 Items to Trash**, a plain bordered button with no Return
  equivalent — a recorded deviation from DES-052, as its import-bar Done case is. Disabled,
  it reads `Move Marked Items to Trash`, with the reason in its tooltip.
- The click acts on exactly the groups on screen. Groups found while the user is looking
  are held back behind `12 more found` with `Show`, so neither the count nor the rows move
  under the pointer.
- No alert beyond APP-045's download question. One undo group, `Undo Move to Trash`,
  restores every item, reselects the Duplicates row and scrolls to the first restored
  group. The trash status bar shows the move; the duplicates bar's L1 drops to what
  remains at once and never says "Moving".

### Card checksums and import (v2)

- Card hashing as in v1: `.removableVolume` becomes hash-required in a lower phase,
  behind metadata and thumbnails, bracketed by ENR-017, quiesced on eject, never a
  download.
- **The staged copy is still hashed** — it is the only read that proves the copy's bytes,
  and a digest is valid only for bytes read (ADR 0018). When the card row carries a
  current digest, the import compares them and fails that entry on a mismatch: the card
  digest turns "copied and verified" into a comparison rather than a stored number.
  Pressing Import never waits for card hashing; an entry without a card digest is copied
  and hashed as today. Whether the staged read limits import throughput is unmeasured —
  no import in the last 14 days logged `op=contentHash` on this Mac — so the plan
  measures it first (`ContentHash` signpost, `elapsedMs` / `mbps`) and only then decides
  whether it needs overlapping with the next copy.
- **Content matches are skipped by the plan,** not deselected: a card item whose digest
  matches an Identical-eligible library row (reachable, enumerated, current, no pending
  trash) is not imported, and L1 `new` excludes it. Import-bar copy merges both reasons
  into the one existing clause — `139 already in Summer Photos`, or `… in your libraries`
  when the matches span libraries. Ready's counts hold until the next state change, and a
  pressed Import imports the plan shown; matches found after Ready wait for the next plan.
- **Erase** keeps its path-proven sentence. A content-matched item is erasable only if,
  at erase time, the matching library row is re-checked as current, reachable and not
  pending trash.

### Open questions for the owner

1. Trash undo restores curation but not edits, and only within the session (APP-039,
   ADR 0022). That gap exists today; a duplicates act makes it more visible. Close it in
   the same work, or separately?
2. Should the bare-key commands exist at all, or menu items only?
3. Calibrating Same photo needs a real library sample; the owner's library is the
   obvious one.
