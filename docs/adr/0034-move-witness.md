# ADR 0034: A move outside Otos keeps its overlay when a byte-free witness proves it

- Status: Accepted
- Last updated: 2026-10-25

## Context

Asset identity is the filesystem path (ADR 0008). A file renamed or moved outside Otos
— in Finder, or on another device and synced down — showed up as one deletion plus one
addition, and the deletion purged everything Otos held for the file: its like or
dislike today, its edit recipe (ADR 0036). The per-file event path
made it worse: a renamed-away path is an `.upsert` event that finds nothing, so the old
row lingered as a stale duplicate until the next full scan purged it.

Checksum identity was rejected (`docs/research/2026-10-24-asset-identity-and-out-of-app-moves.md`):
hashing a moved file downloads it when it is cloud-only, other apps rewrite metadata
in place, and duplicates are ambiguous. The research also measured that a file's
identifier on its volume (its inode) survives a Finder rename or move, and experiment R2
(`2026-10-25-cloud-drives.md`) showed OneDrive applying remote renames and moves as in-place renames:
same inode, same size, same birth time, cloud-only or not, while the modification time
changed on one rename and one move.

## Decision

Every scan upsert records each file's identifier on its volume
(`URLResourceKey.fileIdentifierKey`, the inode) in `media_asset.file_identifier`, an
additive migration (`v2_media_asset_file_identifier`, ARC-043). It is a scan fact like
size and dates, never an identity.

When a scan or a file event upserts a path that has no row,
`CatalogStorePersistence.movedRowWitnessed` looks for the row it moved from. It pairs
only when all of the following hold:

- exactly one row anywhere in the catalog has the same identifier, size and creation
  time (whole seconds);
- that row's root is on the same volume (`st_dev`);
- that row's own path no longer exists on disk (`lstat` → `ENOENT`).

The row then takes the new root and path in the same write, children follow through
`ON UPDATE CASCADE`, and the upsert refreshes its filesystem facts. The pairing is
logged as `op=catalog.scan.reconcile phase=moveWitnessed`. Anything else pairs nothing
and stays the ordinary purge-and-add.

- **Modification time is not in the witness**, because OneDrive rewrites it on remote
  renames and moves. A pair whose modification time changed keeps its enrichment
  stamps, which then mismatch, so the file is enriched again; correctness over a saved
  download.
- **Reads no bytes and downloads nothing.** `lstat` and the resource values are inode
  metadata.

## Consequences

- Finder renames and moves keep their overlay, within a root or across roots on one
  volume, and so do OneDrive's remote renames and moves as measured. The per-file event
  path moves the row at once instead of leaving a stale duplicate.
- Not covered:
  - a move across volumes, which is a copy and a delete with a new identifier;
  - a provider that applies a remote change as delete-and-recreate;
  - an account re-link or reinstall that recreates every file;
  - a file whose old row predates the column, until its first scan records the
    identifier.
- A copy has a new identifier and a hard link keeps its old path, so neither is mistaken
  for a move.
- The first scan after the migration writes the identifier into every row it observes.

## Rejected

- **Checksum identity or relink by hash:** see Context.
- **Thumbnail matching:** needs a rendered thumbnail of the new file, which needs its
  bytes, and still cannot tell duplicates apart.
- **Provider item identifiers** (`NSFileProviderManager.getIdentifierForUserVisibleFile`):
  documented for the provider's own use, failed for a third-party caller in
  `docs/research/2026-10-25-cloud-drives.md`, and unavailable outside a provider domain.
