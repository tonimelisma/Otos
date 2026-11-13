# Plan 0115: Stacks — RAW+JPEG pairs and bursts as one photo

Opened 2026-11-13. Decisions: ADR 0052. Survey:
`docs/research/2026-11-13-stacks-pairs-and-bursts.md`.

## Owner decisions (2026-11-13)

- RAW+JPEG pairs are one photo everywhere, not only in On This Day.
- Bursts are one photo everywhere too ("stack everywhere bursts too").
- A pair shows the camera JPEG by default, as Apple Photos does.
- Switching between RAW and JPEG is prominent, "not buried in a menu": a `JPG`/`RAW` control in
  the edit panel header and on the loupe, and the grid's badge.
- A pair expands like a burst when its badge is clicked.
- A burst expands in place in the grid (Lightroom Classic), not in a separate view.
- Move to Trash on a collapsed burst trashes every frame (Apple Photos).
- Move to Trash on one file of an expanded pair trashes only that file.
- Switching an edited pair's shown file keeps each file's own edit.
- iPhone bursts stack by their burst identifier; camera bursts wait for a measurement of
  timing-based detection on the owner's library.
- On This Day follows Apple Photos: leave out Disliked photos and screenshots or documents, one
  photo per burst, Liked first, a cap per anniversary.
- Approved UI, from the chat mockup:
  - **The tile badge,** bottom right where `RAW` sits today: `RAW+JPG` on a pair, the member
    count on a burst.
  - **Expanding:** a click on the badge or S expands the stack and collapses it again. The
    members sit on a tinted band, with the key member outlined.
  - **Make Key Photo:** ⇧S and Photo ▸ Make Key Photo.
  - **Info** lists every member file.

## Increments

Each increment lands on `main` with its own DoD.

1. **Docs:** the survey, ADR 0052 (Proposed) and this plan. *(done, #676)*
2. **One stem key.** *(done, #680)*
   - One stem-key owner on `FilesystemNameKey` semantics, used by `MediaCompanionPairing`,
     `ImportNaming.bundles` and later stacks.
   - Tests cover case-insensitive and normalization-differing stems on both volume kinds.
3. **Pairs collapse, expand, and take a key.** *(this PR; increments 3 and 4 land together, so a
   collapsed RAW is never unreachable between them)*
   - **Store:** candidate stills read with the order (`PhotoStackSQL`), stacks decided in Swift
     (`PhotoStackRule`).
   - **Projection:** the collapse pass keeps the full order for reuse
     (`CatalogProjectionOrderReuse`), and the key member defaults to the processed file.
   - **Counts:** day counts, On This Day and the map follow from the collapsed order. People's
     photo count counts stack keys.
   - **Trash:** a collapsed pair trashes both files (the window expands the targets). Reveal in
     Finder shows both.
   - **Info** lists both files (`Stack`).
   - **Requirements:** ARC-062, APP-075, APP-076.
   - **Migration v32:** the key-choice stamp on the member it names, carried by moves, purged
     with its row, undoable.
   - **Expanding:** an expanded-stacks window intent outside the descriptor, with the tinted
     band and the outlined key.
   - **The badge** acts as the expand control (hit-tested by the collection view before
     selection), with S, ⇧S and Photo ▸ Expand Stack / Collapse Stack / Make Key Photo.
   - **`JPG`/`RAW`:** the segmented control in the edit panel header and the loupe capsule at
     the top trailing edge (DES-106's place).
   - **Trash** on an expanded member trashes that one file.
   - **Design rules:** DES-116 and DES-117 in `docs/design/design-system.md`, with design review C
     run on light and dark screenshots, grayscale, keyboard and Reduce Motion.
4. **iPhone bursts.** *(done)*
   - **Migration:** `media_asset.burst_identifier`, written with metadata and backfilled from
     `metadata_extra_json`. It joins `EnrichmentOverlayBeforeWrite.changesStructure`.
   - **The burst rule:** a pair is one frame of a burst; the default key is the first Liked
     frame, else the first in capture order. A burst's key choice has its own column
     (`burst_key_chosen_at_unix_ms`), so choosing a frame never clears a pair's choice.
   - **Trash** on a collapsed burst trashes every frame.
   - **Info** reads `Burst · N photos`.
5. **On This Day picks.** *(done but the cap; measured in `docs/research/2026-11-13-on-this-day-picks.md`)*
   - Leave out Disliked photos and put Liked photos first. *(done)*
   - Leave out screenshots and documents by search's confident scene labels, measured on the
     owner's library. *(done)*
   - Cap each anniversary: the owner chooses the cap from the measured day sizes.
6. **Camera bursts: measurement first.** *(measured: `docs/research/2026-11-13-camera-burst-detection.md` — timing cannot tell bursts apart; the camera's maker-note drive mode can; awaiting the owner's decision)*
   - A research note on detecting bursts from capture facts (body serial, sub-seconds, maker
     sequence numbers MediaMetadata can read) on the owner's library, before any rule ships.
   - A rule ships only after the owner decides from that note, with Remove from Burst for a
     wrong guess.
