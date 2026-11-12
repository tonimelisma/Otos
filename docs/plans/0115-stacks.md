# Plan 0115: Stacks — RAW+JPEG pairs and bursts as one photo

Opened 2026-11-13. Decisions: ADR 0052. Survey:
`docs/research/2026-11-13-stacks-pairs-and-bursts.md`.

## Owner decisions (2026-11-13)

- RAW+JPEG pairs are one photo everywhere, not only in On This Day.
- Bursts are one photo everywhere too ("stack everywhere bursts too").
- A pair shows the camera JPEG by default, as Apple Photos does.
- Switching between RAW and JPEG is prominent, "not buried in a menu": a `JPEG | RAW` control in
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

1. **Docs:** the survey, ADR 0052 (Proposed) and this plan. *(this PR)*
2. **One stem key.**
   - One stem-key owner on `FilesystemNameKey` semantics, used by `MediaCompanionPairing`,
     `ImportNaming.bundles` and later stacks.
   - Tests cover case-insensitive and normalization-differing stems on both volume kinds.
3. **Pairs collapse.**
   - **Store:** the order rows carry a stack key (the pair rule only).
   - **Projection:** the collapse pass keeps the full order for reuse
     (`CatalogProjectionOrderReuse`), and the key member defaults to the processed file.
   - **Counts:** day counts, On This Day and the map follow from the collapsed order. People's
     photo count counts stack keys.
   - **Trash:** a collapsed pair trashes both files (`mediaTrashItems`). Reveal in Finder shows
     both.
   - **Info** lists both files.
   - **Requirements:** ARC and APP rows, with their tests.
4. **Expanding and the key choice.**
   - **Migration:** the key-choice table, purged with its member, carried by moves and
     undoable.
   - **Expanding:** an expanded-stacks window intent outside the descriptor, with the tinted
     band and the outlined key.
   - **The badge** acts as the expand control (an `NSButton` in the tile, like the curation
     buttons), with S, ⇧S and Photo ▸ Expand Stack / Collapse Stack / Make Key Photo.
   - **`JPEG | RAW`:** the segmented control in the edit panel header and the loupe capsule at
     the top trailing edge (DES-106's place).
   - **Trash** on an expanded member trashes that one file.
   - **Design rules:** new `DES-*` rules in `docs/design/design-system.md`, with design review C
     run on light and dark screenshots, grayscale, keyboard and Reduce Motion.
5. **iPhone bursts.**
   - **Migration:** `media_asset.burst_identifier`, written with metadata and backfilled from
     `metadata_extra_json`. It joins `EnrichmentOverlayBeforeWrite.changesStructure`.
   - **The burst rule:** a pair is one frame of a burst; the default key is the first Liked
     frame, else the first in capture order.
   - **Trash** on a collapsed burst trashes every frame.
   - **Info** reads `Burst · N photos`.
6. **On This Day picks.**
   - Leave out Disliked photos, put Liked photos first and cap each anniversary.
   - Leave out screenshots and documents, using the platform's utility classification once its
     availability on macOS 27 is verified and measured on the owner's library (a research note).
   - Choose the cap with the owner from that measurement.
7. **Camera bursts: measurement first.**
   - A research note on detecting bursts from capture facts (body serial, sub-seconds, maker
     sequence numbers MediaMetadata can read) on the owner's library, before any rule ships.
   - A rule ships only after the owner decides from that note, with Remove from Burst for a
     wrong guess.
